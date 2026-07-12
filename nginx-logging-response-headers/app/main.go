package main

import (
	"net/http"
	"time"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		//w.WriteHeader(http.StatusOK)
		now := time.Now()
		w.Header().Set("X-Time", now.Format(time.RFC3339))

		w.Write([]byte("Hello World"))
	})

	http.ListenAndServe(":3000", nil)
}
