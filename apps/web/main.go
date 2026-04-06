package main

import (
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
		fmt.Fprintf(w, "web %s | host=%s | path=%s\n", version, hostname, r.URL.Path)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		fmt.Fprintln(w, "ok")
	})

	fmt.Println("web listening on :8080")
	http.ListenAndServe(":8080", nil)
}
