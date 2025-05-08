package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	_ "github.com/mattn/go-sqlite3"
)

// ===== Data Structures =====

type QueryRequest struct {
	SQL    string        `json:"sql"`
	Params []interface{} `json:"params"`
}

// API Description structures
type APIDescription struct {
	APIVersion  string               `json:"apiVersion"`
	Name        string               `json:"name"`
	Description string               `json:"description"`
	BasePath    string               `json:"basePath"`
	Endpoints   []EndpointDefinition `json:"endpoints"`
}

type EndpointDefinition struct {
	Path    string                      `json:"path"`
	Methods map[string]MethodDefinition `json:"methods"`
}

type MethodDefinition struct {
	Description string   `json:"description"`
	SQL         string   `json:"sql"`
	Params      []string `json:"params,omitempty"`
}

type Server struct {
	db            *sql.DB
	apiDesc       *APIDescription
	pathRegexps   map[string]*regexp.Regexp // Cache for compiled path regexps
	showResponses bool                      // Flag to enable/disable response logging
}

// ===== Server Initialization =====

func NewServer(dbPath string, extensionPath string, apiDescPath string, showResponses bool) (*Server, error) {
	// Simple connection string with extension loading enabled
	db, err := sql.Open("sqlite3", dbPath+"?_allow_load_extension=1")
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	// Create memory database for extensions
	if _, err := db.Exec(`ATTACH DATABASE ':memory:' AS extension_mem`); err != nil {
		log.Printf("Failed to attach memory database: %v", err)
	}

	// Enable extension loading via PRAGMA
	if _, err := db.Exec(`PRAGMA load_extension = 1;`); err != nil {
		log.Printf("Warning: PRAGMA load_extension failed: %v", err)
	}

	// If extension is provided, try to load it
	if extensionPath != "" {
		// Get the absolute path to the extension file
		absPath, err := filepath.Abs(extensionPath)
		if err != nil {
			log.Printf("Warning: failed to get absolute path: %v", err)
			absPath = "./" + extensionPath
		}

		// Ensure file has execute permissions (required for Linux)
		if err := os.Chmod(absPath, 0755); err != nil {
			log.Printf("Warning: failed to set execute permissions on extension: %v", err)
		}

		// Log extension loading attempt
		log.Printf("Trying to load extension: %s", absPath)

		// Attempt to load the extension
		if _, err := db.Exec(`SELECT load_extension(?)`, absPath); err != nil {
			log.Printf("Extension loading failed: %v", err)
		} else {
			log.Println("Extension loaded successfully")
		}
	}

	// Initialize the server
	server := &Server{
		db:            db,
		pathRegexps:   make(map[string]*regexp.Regexp),
		showResponses: showResponses,
	}

	// Load the API description if provided
	if apiDescPath != "" {
		if _, err := os.Stat(apiDescPath); os.IsNotExist(err) {
			log.Printf("API description file not found: %s", apiDescPath)
		} else {
			apiDesc, err := loadAPIDescription(apiDescPath)
			if err != nil {
				log.Printf("Warning: Failed to load API description: %v", err)
			} else {
				server.apiDesc = &apiDesc
				log.Printf("API description loaded successfully: %s (v%s)", apiDesc.Name, apiDesc.APIVersion)

				// Precompile the path regexps for faster matching
				for _, endpoint := range apiDesc.Endpoints {
					pathRegexp := pathToRegexp(endpoint.Path)
					server.pathRegexps[endpoint.Path] = regexp.MustCompile(pathRegexp)
				}
			}
		}
	}

	return server, nil
}

// ===== API Description Handling =====

// Load API description from file
func loadAPIDescription(filePath string) (APIDescription, error) {
	var apiDesc APIDescription
	data, err := os.ReadFile(filePath)
	if err != nil {
		return apiDesc, fmt.Errorf("failed to read API description file: %w", err)
	}

	err = json.Unmarshal(data, &apiDesc)
	if err != nil {
		return apiDesc, fmt.Errorf("failed to parse API description JSON: %w", err)
	}

	return apiDesc, nil
}

// Convert a path template to a regexp
// Example: "/clients/:id" -> "^/clients/([^/]+)$"
func pathToRegexp(path string) string {
	// Escape any special regexp characters in the path
	escaped := regexp.QuoteMeta(path)

	// Replace :paramName with a capturing group
	re := regexp.MustCompile(`:([^/]+)`)
	regexpPath := re.ReplaceAllString(escaped, "([^/]+)")

	// Add start and end anchors
	return fmt.Sprintf("^%s$", regexpPath)
}

// Extract path parameters from a URL based on the endpoint path template
// Example: extractPathParams("/clients/123", "/clients/:id") -> {"id": "123"}
func extractPathParams(requestPath string, endpointPath string, re *regexp.Regexp) map[string]string {
	params := make(map[string]string)

	// Extract param names from the path template
	paramNames := make([]string, 0)
	pathParts := strings.Split(endpointPath, "/")
	for _, part := range pathParts {
		if strings.HasPrefix(part, ":") {
			paramNames = append(paramNames, part[1:])
		}
	}

	// Extract values using regexp
	matches := re.FindStringSubmatch(requestPath)
	if len(matches) > 1 {
		// First match is the whole string, subsequent matches are capture groups
		for i, name := range paramNames {
			if i+1 < len(matches) {
				params[name] = matches[i+1]
			}
		}
	}

	return params
}

// Find the matching endpoint for a request path
func (s *Server) findMatchingEndpoint(requestPath string) (*EndpointDefinition, map[string]string) {
	if s.apiDesc == nil {
		return nil, nil
	}

	// Strip base path if present
	basePath := s.apiDesc.BasePath
	if basePath != "" && strings.HasPrefix(requestPath, basePath) {
		requestPath = strings.TrimPrefix(requestPath, basePath)
		if requestPath == "" {
			requestPath = "/"
		}
	}

	// Normalize the path by removing trailing slashes
	normalizedPath := strings.TrimSuffix(requestPath, "/")
	if normalizedPath == "" {
		normalizedPath = "/"
	}

	log.Printf("Trying to match path: %s (normalized: %s)", requestPath, normalizedPath)

	// First try exact match with normalized path
	for _, endpoint := range s.apiDesc.Endpoints {
		re, exists := s.pathRegexps[endpoint.Path]
		if !exists {
			// This shouldn't happen as we precompile all regexps
			log.Printf("Warning: No regexp for path %s", endpoint.Path)
			continue
		}

		if re.MatchString(normalizedPath) {
			log.Printf("Matched endpoint %s with normalized path", endpoint.Path)
			params := extractPathParams(normalizedPath, endpoint.Path, re)
			return &endpoint, params
		}
	}

	// If we reach here, try matching with the original path as a fallback
	if normalizedPath != requestPath {
		for _, endpoint := range s.apiDesc.Endpoints {
			re, exists := s.pathRegexps[endpoint.Path]
			if !exists {
				continue
			}

			if re.MatchString(requestPath) {
				log.Printf("Matched endpoint %s with original path", endpoint.Path)
				params := extractPathParams(requestPath, endpoint.Path, re)
				return &endpoint, params
			}
		}
	}

	log.Printf("No matching endpoint found for path: %s", requestPath)
	return nil, nil
}

// ===== Parameter Extraction =====

// Extract query parameters from request URL
func extractQueryParams(r *http.Request) map[string]string {
	queryParams := make(map[string]string)
	for key, values := range r.URL.Query() {
		if len(values) > 0 {
			queryParams[key] = values[0]
		}
	}
	return queryParams
}

// Extract JSON body parameters from request
func extractBodyParams(r *http.Request) (map[string]interface{}, error) {
	bodyParams := make(map[string]interface{})

	if r.Body == nil {
		return bodyParams, nil
	}

	var bodyBuffer bytes.Buffer
	bodyReader := io.TeeReader(r.Body, &bodyBuffer)

	bodyBytes, err := io.ReadAll(bodyReader)
	if err != nil {
		return bodyParams, err
	}

	if len(bodyBytes) > 0 {
		err = json.Unmarshal(bodyBytes, &bodyParams)
		if err != nil {
			return bodyParams, err
		}
	}

	// Reset r.Body for potential future use
	r.Body = io.NopCloser(&bodyBuffer)

	return bodyParams, nil
}

// ===== SQL Execution =====

// Execute SQL query and return results as maps
func (s *Server) executeQuery(sqlQuery string, params []interface{}) ([]map[string]interface{}, error) {
	// Log the query and params
	log.Printf("Executing SQL: %s with params: %v", sqlQuery, params)

	// Execute the query
	rows, err := s.db.Query(sqlQuery, params...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Get column information
	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}

	// Process result rows
	var result []map[string]interface{}
	for rows.Next() {
		// Create values slice with appropriate length
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range columns {
			valuePtrs[i] = &values[i]
		}

		// Scan the row into values
		if err := rows.Scan(valuePtrs...); err != nil {
			return nil, err
		}

		// Create a map for this row
		entry := make(map[string]interface{})
		for i, col := range columns {
			var v interface{}
			val := values[i]
			b, ok := val.([]byte)
			if ok {
				v = string(b)
			} else {
				v = val
			}
			entry[col] = v
		}

		// Add the row to the result
		result = append(result, entry)
	}

	// Check for errors after iteration
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Log the response if enabled
	if s.showResponses {
		responseJSON, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			log.Printf("Error marshaling response for logging: %v", err)
		} else {
			log.Printf("Response: %s", string(responseJSON))
		}
	}

	return result, nil
}

// ===== HTTP Response Handling =====

// Send JSON response with the given status code
func (s *Server) sendJSONResponse(w http.ResponseWriter, data interface{}, statusCode int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)

	// Generate JSON response
	responseJSON, err := json.Marshal(data)
	if err != nil {
		log.Printf("Error encoding JSON response: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Log the response if enabled
	if s.showResponses {
		var prettyJSON bytes.Buffer
		if err := json.Indent(&prettyJSON, responseJSON, "", "  "); err != nil {
			log.Printf("Error prettifying JSON for logging: %v", err)
		} else {
			log.Printf("Sending response: %s", prettyJSON.String())
		}
	}

	// Send the response
	if _, err := w.Write(responseJSON); err != nil {
		log.Printf("Error writing response: %v", err)
	}
}

// Send error response with the given status code
func sendErrorResponse(w http.ResponseWriter, message string, statusCode int) {
	log.Printf("Error: %s (Status: %d)", message, statusCode)
	http.Error(w, message, statusCode)
}

// ===== Request Handlers =====

// Handle API requests based on the API description
func (s *Server) handleAPI(w http.ResponseWriter, r *http.Request) {
	log.Printf("Handling API request for %s %s", r.Method, r.URL.Path)

	if s.apiDesc == nil {
		sendErrorResponse(w, "API description not loaded", http.StatusInternalServerError)
		return
	}

	// Find the matching endpoint
	endpoint, pathParams := s.findMatchingEndpoint(r.URL.Path)
	if endpoint == nil {
		log.Printf("No endpoint found for %s %s", r.Method, r.URL.Path)
		http.NotFound(w, r)
		return
	}

	log.Printf("Found endpoint %s for %s %s", endpoint.Path, r.Method, r.URL.Path)

	// Check if the method is supported
	methodDef, exists := endpoint.Methods[r.Method]
	if !exists {
		log.Printf("Method %s not allowed for endpoint %s", r.Method, endpoint.Path)
		sendErrorResponse(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract parameters
	queryParams := extractQueryParams(r)

	bodyParams, err := extractBodyParams(r)
	if err != nil {
		log.Printf("Warning: Failed to parse request body as JSON: %v", err)
	}

	// Prepare SQL query
	sqlQuery := methodDef.SQL

	// Replace named parameters with ? placeholders and build params array
	var sqlParams []interface{}

	// If we have defined params, use them in order
	if len(methodDef.Params) > 0 {
		for _, paramName := range methodDef.Params {
			// Check path params first, then query params, then body params
			if value, ok := pathParams[paramName]; ok {
				sqlParams = append(sqlParams, value)
				sqlQuery = strings.Replace(sqlQuery, ":"+paramName, "?", 1)
			} else if value, ok := queryParams[paramName]; ok {
				sqlParams = append(sqlParams, value)
				sqlQuery = strings.Replace(sqlQuery, ":"+paramName, "?", 1)
			} else if value, ok := bodyParams[paramName]; ok {
				sqlParams = append(sqlParams, value)
				sqlQuery = strings.Replace(sqlQuery, ":"+paramName, "?", 1)
			} else {
				// Parameter not found, add nil
				sqlParams = append(sqlParams, nil)
				sqlQuery = strings.Replace(sqlQuery, ":"+paramName, "?", 1)
			}
		}
	}

	// Execute the query
	result, err := s.executeQuery(sqlQuery, sqlParams)
	if err != nil {
		sendErrorResponse(w, fmt.Sprintf("Database error: %v", err), http.StatusInternalServerError)
		return
	}

	// Return response
	s.sendJSONResponse(w, result, http.StatusOK)
}

// Handle direct SQL query requests
func (s *Server) handleQuery(w http.ResponseWriter, r *http.Request) {
	log.Printf("Handling query request from %s", r.URL.Path)

	if r.Method != "POST" {
		sendErrorResponse(w, "Only POST method is allowed", http.StatusMethodNotAllowed)
		return
	}

	// Use io.TeeReader to log the body while still allowing it to be read
	var bodyBuffer bytes.Buffer
	teeReader := io.TeeReader(r.Body, &bodyBuffer)

	// Log the body as a string
	bodyBytes, err := io.ReadAll(teeReader)
	if err != nil {
		sendErrorResponse(w, "Failed to read request body", http.StatusInternalServerError)
		return
	}
	log.Printf("Request Body: %s", string(bodyBytes))

	// Decode the body into the QueryRequest struct
	var req QueryRequest
	if err := json.NewDecoder(&bodyBuffer).Decode(&req); err != nil {
		sendErrorResponse(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Execute the query
	result, err := s.executeQuery(req.SQL, req.Params)
	if err != nil {
		sendErrorResponse(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Return response
	s.sendJSONResponse(w, result, http.StatusOK)
}

// Handle proxy requests
func (s *Server) handleProxy(w http.ResponseWriter, r *http.Request) {
	// 1. Parse off the part after "/proxy/".
	targetPath := strings.TrimPrefix(r.URL.Path, "/proxy/")
	targetQuery := r.URL.RawQuery

	// 2. Split off the first segment as the actual host.
	pathParts := strings.SplitN(targetPath, "/", 2)
	hostPart := pathParts[0]

	// 3. The remainder is your path on that host.
	var subPath string
	if len(pathParts) > 1 {
		subPath = "/" + pathParts[1]
	} else {
		subPath = "/"
	}

	// 4. Construct a "bare" target with no path so the default Director won't double up paths.
	rawTarget := "https://" + hostPart
	targetURL, err := url.Parse(rawTarget)
	if err != nil {
		sendErrorResponse(w, "Invalid target URL: "+err.Error(), http.StatusBadRequest)
		return
	}

	// 5. Create the reverse proxy.
	proxy := httputil.NewSingleHostReverseProxy(targetURL)

	// 6. Update the inbound request with subPath and query
	r.URL.Scheme = targetURL.Scheme
	r.URL.Host = targetURL.Host
	r.URL.Path = subPath
	r.URL.RawQuery = targetQuery

	// 7. (Optional) Reassign the Host header to match target
	r.Host = targetURL.Host

	// 8. Finally, run the proxy
	proxy.ServeHTTP(w, r)
}

func launchBrowser(url string) {
	var cmd string
	var args []string

	switch runtime.GOOS {
	case "darwin":
		cmd = "open"
		args = []string{url}
	case "windows":
		cmd = "rundll32"
		args = []string{"url.dll,FileProtocolHandler", url}
	default: // Unix-like
		cmd = "xdg-open"
		args = []string{url}
	}

	err := exec.Command(cmd, args...).Start()
	if err != nil {
		log.Printf("Failed to launch browser: %v", err)
	}
}

// ===== Main Application =====

func main() {
	// disable steampipe cache
	os.Setenv("STEAMPIPE_CACHE", "false")

	// Set custom flag usage to display double dashes for word options
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage of %s:\n", os.Args[0])
		flag.VisitAll(func(f *flag.Flag) {
			prefix := "-"
			// Use double dash for multi-character flags
			if len(f.Name) > 1 {
				prefix = "--"
			}
			fmt.Fprintf(flag.CommandLine.Output(), "  %s%s: %s\n", prefix, f.Name, f.Usage)
		})
	}

	// Set up command line flags with long and short versions
	var portValue string
	flag.StringVar(&portValue, "port", "8080", "Port to run the server on")
	flag.StringVar(&portValue, "p", "8080", "Port to run the server on (shorthand)")
	extension := flag.String("extension", "", "Path to SQLite extension to load")
	apiDesc := flag.String("api", "", "Path to API description file")
	showResponses := flag.Bool("show-responses", false, "Enable logging of SQL query responses")

	// Short-form alias for show-responses
	var shortShowResponses bool
	flag.BoolVar(&shortShowResponses, "s", false, "Enable logging of SQL query responses (shorthand)")

	flag.Parse()

	// Set up logging
	log.SetFlags(log.Lshortfile | log.LstdFlags)
	log.Println("Server starting...")

	// Print current working directory
	pwd, err := os.Getwd()
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("Working directory: %s", pwd)

	// Initialize server
	showResponsesEnabled := *showResponses || shortShowResponses
	server, err := NewServer("data.db", *extension, *apiDesc, showResponsesEnabled)
	if err != nil {
		log.Fatal(err)
	}

	// Create router
	mux := http.NewServeMux()

	corsMiddleware := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "*")

			if r.Method == "OPTIONS" {
				w.WriteHeader(http.StatusOK)
				return
			}

			next.ServeHTTP(w, r)
		})
	}

	// Handle API routes first (to match /api/* before static files)
	if server.apiDesc != nil {
		apiBasePath := server.apiDesc.BasePath
		if !strings.HasSuffix(apiBasePath, "/") {
			apiBasePath += "/"
		}
		mux.HandleFunc(apiBasePath, server.handleAPI)
	}

	// Handle proxy next
	mux.HandleFunc("/proxy/", server.handleProxy)

	// Then handle query endpoint
	mux.HandleFunc("/query", server.handleQuery)

	// Handle root and static files
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Received request for: %s", r.URL.Path)

		if r.URL.Path == "/" {
			log.Println("Trying to serve index.html")
			http.ServeFile(w, r, "index.html")
			return
		}

		filePath := "." + r.URL.Path
		log.Printf("Trying to serve: %s", filePath)
		if _, err := os.Stat(filePath); os.IsNotExist(err) {
			log.Printf("File not found: %s", filePath)
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, filePath)
	})

	// Log server settings
	log.Printf("Server configuration:")
	log.Printf("- Port: %s", portValue)
	log.Printf("- API Description: %s", *apiDesc)
	log.Printf("- Extension: %s", *extension)
	log.Printf("- Show Responses: %v", showResponsesEnabled)

	// Start server
	launchBrowser("http://localhost:" + portValue)
	log.Printf("Server listening on port %s...", portValue)
	if err := http.ListenAndServe(":"+portValue, corsMiddleware(mux)); err != nil {
		log.Fatal(err)
	}

}
