package main

import (
	"os"
	"log"
	"net/http"
	"encoding/json"
)

type Pod struct {
	Namespace string `json:"namespace"`
	Name string `json:"name"`
	Status string `json:"status"`
}

func handleApiPods(w http.ResponseWriter, r *http.Request) {
	pods := []Pod{
		Pod {
			Namespace: "default",
			Name: "test-xxx",
			Status: "Running",
		},
		Pod {
			Namespace: "kube-system",
			Name: "coredns-yyy",
			Status: "Running",
		},
	}

	w.Header().Set("Content-Type", "application/json")
	result, err := json.Marshal(pods)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Write(result)
}

func main() {
	http.Handle("/", http.FileServer(http.Dir("./public")))
	http.HandleFunc("/api/pods", handleApiPods)

	port := os.Getenv("PORT")
	if (len(port) == 0) {
		port = "8080"
	}
	log.Println("Listening on :" + port + "...")
	err := http.ListenAndServe(":" + port, nil)
	if err != nil {
		log.Fatal(err)
	}
}
