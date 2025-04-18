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

func checkSQLiteCompileOptionUsed(db *sql.DB) {
	log.Println("🔍 Checking sqlite3_compileoption_used() at runtime:")

	options := []string{
		"SQLITE_ENABLE_LOAD_EXTENSION",
		"SQLITE_ALLOW_LOAD_EXTENSION",
	}

	for _, opt := range options {
		var enabled int
		err := db.QueryRow(`SELECT sqlite_compileoption_used(?)`, opt).Scan(&enabled)
		if err != nil {
			log.Printf("Error checking option %s: %v", opt, err)
		} else if enabled == 1 {
			log.Printf("✅ Runtime compile option enabled: %s", opt)
		} else {
			log.Printf("⚠️ Runtime compile option NOT enabled: %s", opt)
		}
	}
}

func NewServer(dbPath string) (*Server, error) {
	db, err := sql.Open("sqlite3", dbPath+"?_allow_load_extension=1")
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)


    // 🔥 Force enable load_extension immediately
    if _, err := db.Exec(`SELECT sqlite3_enable_load_extension(1)`); err != nil {
        log.Printf("⚠️ Failed to enable load_extension at runtime: %v", err)
    } else {
        log.Println("✅ Successfully enabled load_extension at runtime")
    }

    log.Println("🔍 Checking sqlite3_compileoption_used() at runtime:")

	checkSQLiteCompileOptionUsed(db)

	if tryDynamicExtensionLoading(db) {
		log.Println("✅ Dynamic extension loading succeeded")
	} else {
		log.Println("⚠️ Dynamic extension loading failed, attempting static extension initialization")
		if err := StaticExtensionInit(db); err != nil {
			log.Printf("⚠️ Static extension initialization failed: %v", err)
		}
	}

	return &Server{db: db}, nil
}

// tryDynamicExtensionLoading attempts to load the extension dynamically
// Returns true if successful, false otherwise
func tryDynamicExtensionLoading(db *sql.DB) bool {
    const extensionPath = "steampipe_sqlite_github.so"

    if _, statErr := os.Stat(extensionPath); statErr == nil {
        // Attach in-memory DB for Steampipe
        if _, err := db.Exec(`ATTACH DATABASE ':memory:' AS githubmem`); err != nil {
            log.Printf("Failed to attach memory database: %v", err)
            return false
        }

        // Get absolute path to extension for more reliable loading
        absExtensionPath, err := filepath.Abs(extensionPath)
        if err != nil {
            log.Printf("Warning: failed to get absolute path for extension %s: %v", extensionPath, err)
            absExtensionPath = extensionPath
        }

        // Try different approaches for loading the extension
        loadExtensionMethods := []struct {
            desc string
            query string
            args []interface{}
        }{
            {"standard way", `SELECT load_extension(?)`, []interface{}{absExtensionPath}},
            {"without extension", `SELECT load_extension(?)`, []interface{}{strings.TrimSuffix(absExtensionPath, ".so")}},
            {"direct query", fmt.Sprintf(`SELECT load_extension('%s')`, absExtensionPath), nil},
            {"with relative path", `SELECT load_extension(?)`, []interface{}{extensionPath}},
        }

        extensionLoaded := false
        var lastError error

        for _, method := range loadExtensionMethods {
            log.Printf("Trying to load extension using %s", method.desc)
            if method.args != nil {
                _, err = db.Exec(method.query, method.args...)
            } else {
                _, err = db.Exec(method.query)
            }

            if err != nil {
                log.Printf("Warning: failed to load extension %s (%s): %v", extensionPath, method.desc, err)
                lastError = err
                continue
            }

            log.Printf("Extension %s loaded successfully using %s", extensionPath, method.desc)
            extensionLoaded = true
            break
        }

        if !extensionLoaded {
            log.Printf("ERROR: Could not load extension %s after all attempts: %v", extensionPath, lastError)
            return false
        }

        // Extension loaded successfully
        return true

    } else if os.IsNotExist(statErr) {
        log.Printf("Extension %s not found, skipping dynamic load", extensionPath)
    } else {
        log.Printf("Error checking extension %s: %v", extensionPath, statErr)
    }

    return false
}


// StaticExtensionInit initializes a minimal environment for when extensions can't be loaded
// This provides a fallback so the server can run without dynamic extension loading
func StaticExtensionInit(db *sql.DB) error {
    log.Println("Setting up minimal static environment (no extension functionality)")

    // Just attach the memory database to prevent errors
    if _, err := db.Exec(`ATTACH DATABASE ':memory:' AS githubmem`); err != nil {
        return fmt.Errorf("failed to attach memory database: %w", err)
    }

    log.Println("✅ Server will run without GitHub extension functionality")
    return nil
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

	/*
	responseJSON, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		log.Printf("Error marshaling response for logging: %v", err)
	} else {
		log.Printf("Response Body: %s", string(responseJSON))
	}
    */

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *Server) handleProxy(w http.ResponseWriter, r *http.Request) {
    // 1. Parse off the part after "/proxy/".
    //    Suppose user hits: GET /proxy/api.hubapi.com/crm/v3/objects/contacts?properties=...
    //    Then targetPath = "api.hubapi.com/crm/v3/objects/contacts"
    targetPath := strings.TrimPrefix(r.URL.Path, "/proxy/")
    targetQuery := r.URL.RawQuery

    // 2. Split off the first segment as the actual host.
    //    pathParts[0] = "api.hubapi.com"
    //    pathParts[1] = "crm/v3/objects/contacts"
    pathParts := strings.SplitN(targetPath, "/", 2)
    hostPart := pathParts[0]

    // 3. The remainder is your path on that host.
    var subPath string
    if len(pathParts) > 1 {
        subPath = "/" + pathParts[1] // => "/crm/v3/objects/contacts"
    } else {
        subPath = "/"
    }

    // 4. Construct a "bare" target with no path so the default Director won't double up paths.
    rawTarget := "https://" + hostPart // e.g. "https://api.hubapi.com"
    targetURL, err := url.Parse(rawTarget)
    if err != nil {
        http.Error(w, "Invalid target URL: "+err.Error(), http.StatusBadRequest)
        return
    }

    // 5. Create the reverse proxy.
    proxy := httputil.NewSingleHostReverseProxy(targetURL)

    // 6. Update the inbound request with subPath and query
    r.URL.Scheme = targetURL.Scheme
    r.URL.Host   = targetURL.Host
    r.URL.Path   = subPath
    r.URL.RawQuery = targetQuery

    // 7. (Optional) Reassign the Host header to match target
    r.Host = targetURL.Host

    // 8. Finally, run the proxy
    proxy.ServeHTTP(w, r)
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

		if r.URL.Path == "/" {
			log.Println("Trying to serve index.html")
			http.ServeFile(w, r, "index.html")
			return
		}

		/*
		if strings.HasPrefix(r.URL.Path, "/xmlui-hubspot/") {
			relativePath := "." + strings.TrimPrefix(r.URL.Path, "/xmlui-hubspot")
			log.Printf("Serving XMLUI file: %s", relativePath)
			http.ServeFile(w, r, relativePath)
			return
		}

		if strings.HasPrefix(r.URL.Path, "/xmlui-hn/") {
			relativePath := "." + strings.TrimPrefix(r.URL.Path, "/xmlui-hn")
			log.Printf("Serving XMLUI file: %s", relativePath)
			http.ServeFile(w, r, relativePath)
			return
		}

		if strings.HasPrefix(r.URL.Path, "/xmlui-cms/") {
			relativePath := "." + strings.TrimPrefix(r.URL.Path, "/xmlui-cms")
			log.Printf("Serving XMLUI file: %s", relativePath)
			http.ServeFile(w, r, relativePath)
			return
		}
		*/

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
