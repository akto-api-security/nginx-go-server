package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type ResponsePayload struct {
	ID        string        `json:"id"`
	SizeType  string        `json:"size_type"`
	Timestamp int64         `json:"timestamp"`
	Message   string        `json:"message"`
	Items     []PayloadItem `json:"items"`
}

type PayloadItem struct {
	Index       int    `json:"index"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Metadata    string `json:"metadata"`
}

var (
	smallPayloads  [][]byte
	mediumPayloads [][]byte
	largePayloads  [][]byte
	counter        uint64
)

func makePayload(sizeType string, targetBytes int, variant int) []byte {
	items := make([]PayloadItem, 0, 1000)

	baseText := strings.Repeat(
		fmt.Sprintf("static-json-%s-variant-%d-data-", sizeType, variant),
		20,
	)

	payload := ResponsePayload{
		ID:        fmt.Sprintf("%s-%d", sizeType, variant),
		SizeType:  sizeType,
		Timestamp: time.Now().Unix(),
		Message:   fmt.Sprintf("This is a %s static JSON payload variant %d", sizeType, variant),
		Items:     items,
	}

	for i := 0; ; i++ {
		payload.Items = append(payload.Items, PayloadItem{
			Index:       i,
			Name:        fmt.Sprintf("%s-item-%d", sizeType, i),
			Description: baseText,
			Metadata:    strings.Repeat("metadata-value-", 10),
		})

		b, err := json.Marshal(payload)
		if err != nil {
			panic(err)
		}

		if len(b) >= targetBytes {
			return b
		}
	}
}

func pick(payloads [][]byte) []byte {
	n := atomic.AddUint64(&counter, 1)
	idx := int(n % uint64(len(payloads)))
	return payloads[idx]
}

func writeJSON(w http.ResponseWriter, payload []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(payload)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func smallHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, pick(smallPayloads))
}

func mediumHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, pick(mediumPayloads))
}

func largeHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, pick(largePayloads))
}

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())

	for i := 0; i < 8; i++ {
		smallPayloads = append(smallPayloads, makePayload("small", 5*1024+(i*600), i))
	}

	for i := 0; i < 8; i++ {
		mediumPayloads = append(mediumPayloads, makePayload("medium", 50*1024+(i*6*1024), i))
	}

	for i := 0; i < 8; i++ {
		largePayloads = append(largePayloads, makePayload("large", 500*1024+(i*60*1024), i))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/small", smallHandler)
	mux.HandleFunc("/medium", mediumHandler)
	mux.HandleFunc("/large", largeHandler)

	server := &http.Server{
		Addr:              "127.0.0.1:9000",
		Handler:           mux,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		ReadHeaderTimeout: 2 * time.Second,
	}

	log.Println("Backend running on 127.0.0.1:9000")
	log.Println("Endpoints: /health /small /medium /large")
	log.Fatal(server.ListenAndServe())
}
