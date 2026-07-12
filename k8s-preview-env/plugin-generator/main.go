package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
)

type PluginInput struct {
	Parameters struct {
		Branch     string `json:"branch"`
		BranchSlug string `json:"branch_slug"`
		Number     string `json:"number"`
		HeadSHA    string `json:"head_sha"`
	} `json:"parameters"`
}

type PluginOutput struct {
	Parameters []map[string]string `json:"parameters"`
}

var (
	githubToken string
	githubOwner string
	repos       []string
)

func init() {
	githubToken = os.Getenv("GITHUB_TOKEN")
	githubOwner = os.Getenv("GITHUB_OWNER")
	repoList := os.Getenv("REPOS")
	if repoList != "" {
		repos = strings.Split(repoList, ",")
	}
}

func branchExists(owner, repo, branch string) bool {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/branches/%s", owner, repo, branch)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return false
	}
	if githubToken != "" {
		req.Header.Set("Authorization", "Bearer "+githubToken)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode == 200
}

func resolveRevision(owner, repo, branch string) string {
	if branchExists(owner, repo, branch) {
		return branch
	}
	return "main"
}

func handleGetParams(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var input PluginInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	branch := input.Parameters.Branch
	params := map[string]string{
		"previewId": input.Parameters.Number,
		"branch":    branch,
	}

	for _, repo := range repos {
		revision := resolveRevision(githubOwner, repo, branch)
		key := strings.ReplaceAll(repo, "-", "_") + "_revision"
		params[key] = revision
	}

	output := PluginOutput{
		Parameters: []map[string]string{params},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(output)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func main() {
	http.HandleFunc("/api/v1/getparams.execute", handleGetParams)
	http.HandleFunc("/healthz", handleHealth)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("plugin-generator listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
