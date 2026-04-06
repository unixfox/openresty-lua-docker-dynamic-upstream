package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

func main() {
	hostname, _ := os.Hostname()
	version := os.Getenv("APP_VERSION")
	if version == "" {
		version = "v1"
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"service":  "api",
			"version":  version,
			"hostname": hostname,
			"path":     r.URL.Path,
		})
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprintln(w, "ok")
	})

	fmt.Println("api listening on :9090")
	http.ListenAndServe(":9090", nil)
}
