package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	_ "github.com/mattn/go-sqlite3"
)

type QueryRequest struct {
	SQL    string        `json:"sql"`
	Params []interface{} `json:"params"`
}

type Server struct {
	db *sql.DB
}

func NewServer(dbPath string) (*Server, error) {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, err
	}
	return &Server{db: db}, nil
}

func (s *Server) handleQuery(w http.ResponseWriter, r *http.Request) {
	log.Printf("Handling query request from %s", r.URL.Path)

	if r.Method != "POST" {
		http.Error(w, "Only POST method is allowed", http.StatusMethodNotAllowed)
		return
	}

	// Use io.TeeReader to log the body while still allowing it to be read
	var bodyBuffer bytes.Buffer
	teeReader := io.TeeReader(r.Body, &bodyBuffer)

	// Log the body as a string
	bodyBytes, err := io.ReadAll(teeReader)
	if err != nil {
		http.Error(w, "Failed to read request body", http.StatusInternalServerError)
		return
	}
	log.Printf("Request Body: %s", string(bodyBytes))

	// Decode the body into the QueryRequest struct
	var req QueryRequest
	if err := json.NewDecoder(&bodyBuffer).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	rows, err := s.db.Query(req.SQL, req.Params...)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var result []map[string]interface{}
	for rows.Next() {
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range columns {
			valuePtrs[i] = &values[i]
		}

		if err := rows.Scan(valuePtrs...); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

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
		result = append(result, entry)
	}

	// Log the response before sending it
	responseJSON, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		log.Printf("Error marshaling response for logging: %v", err)
	} else {
		log.Printf("Response Body: %s", string(responseJSON))
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *Server) handleProxy(w http.ResponseWriter, r *http.Request) {
	log.Printf("Handling proxy request from %s", r.URL.Path)
	// Extract the target URL from the path
	targetURL := r.URL.Path[len("/proxy/"):]
	if !strings.HasPrefix(targetURL, "http") {
		targetURL = "https://" + targetURL
	}

	// Create the proxy request
	proxyReq, err := http.NewRequest(r.Method, targetURL, r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Copy original headers
	for header, values := range r.Header {
		for _, value := range values {
			proxyReq.Header.Add(header, value)
		}
	}

	// Make the request
	client := &http.Client{}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Set CORS headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "*")

	// Copy response headers
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}

	// Set response status code
	w.WriteHeader(resp.StatusCode)

	// Copy response body
	io.Copy(w, resp.Body)
}

func main() {
	// Set up command line flags
	port := flag.String("port", "8080", "Port to run the server on")
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

	// List files in current directory
	files, err := filepath.Glob("*")
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("Files in directory: %v", files)

	// Initialize server
	server, err := NewServer("data.db")
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

	// Handle proxy first (more specific)
	mux.HandleFunc("/proxy/", server.handleProxy)

	// Then handle other routes
	mux.HandleFunc("/query", server.handleQuery)

	// Handle root and static files
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Received request for: %s", r.URL.Path)

		// If root path, try to serve index.html
		if r.URL.Path == "/" {
			log.Println("Trying to serve index.html")
			http.ServeFile(w, r, "index.html")
			return
		}

		// Otherwise serve the requested file
		filePath := "." + r.URL.Path
		log.Printf("Trying to serve: %s", filePath)
		if _, err := os.Stat(filePath); os.IsNotExist(err) {
			log.Printf("File not found: %s", filePath)
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, filePath)
	})

	// Start server
	log.Printf("Server listening on port %s...", *port)
	if *port == "" {
		*port = "8080"
	}
	if err := http.ListenAndServe(":" +  *port, corsMiddleware(mux)); err != nil {
		log.Fatal(err)
	}
}
