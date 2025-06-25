package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

func makeRequest(req *http.Request, response response) *http.Response {

	client := &http.Client{
		Timeout: time.Second * 3,
	}

	res, err := client.Do(req)

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return nil
	}

	return res
}

func makeResponse(httpResponse *http.Response, response response) {
	response.SetHeader(httpResponse.Header)

	defer httpResponse.Body.Close()

	body, err := io.ReadAll(httpResponse.Body)

	if err != nil && httpResponse.StatusCode != 200 {
		response.setStatusCode(httpResponse.StatusCode).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	var content any
	err = json.Unmarshal(body, &content)

	if err != nil && httpResponse.StatusCode != 200 {
		response.setStatusCode(httpResponse.StatusCode).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	response.setStatusCode(httpResponse.StatusCode).setContent(content).write()
}

func getRequest() {
	req, err := http.NewRequest("GET", args.URL, strings.NewReader(""))

	response := response{
		StatusCode: 200,
		Content:    nil,
	}

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	res := makeRequest(req, response)

	makeResponse(res, response)

}

func postRequest() {

	response := response{
		StatusCode: 200,
		Content:    nil,
		Request:    args.Data,
	}

	response.setRequest(args.Data)

	req, err := http.NewRequest("POST", args.URL, strings.NewReader(args.Data))

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	req.Header.Set("Content-Type", "application/json")

	res := makeRequest(req, response)

	if res != nil {
		makeResponse(res, response)
	}
}

func putRequest() {

	response := response{
		StatusCode: 200,
		Content:    nil,
	}

	response.setRequest(args.Data)

	req, err := http.NewRequest("PUT", args.URL, strings.NewReader(args.Data))

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	req.Header.Set("Content-Type", "application/json")

	res := makeRequest(req, response)

	if res != nil {
		makeResponse(res, response)
	}
}

func patchRequest() {

	response := response{
		StatusCode: 200,
		Content:    nil,
	}

	response.setRequest(args.Data)

	req, err := http.NewRequest("PATCH", args.URL, strings.NewReader(args.Data))

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	req.Header.Set("Content-Type", "application/json")

	res := makeRequest(req, response)

	if res != nil {
		makeResponse(res, response)
	}
}

func deleteRequest() {

	response := response{
		StatusCode: 200,
		Content:    nil,
	}

	req, err := http.NewRequest("DELETE", args.URL, strings.NewReader(args.Data))

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	req.Header.Set("Content-Type", "application/json")

	res := makeRequest(req, response)

	if res != nil {
		makeResponse(res, response)
	}
}
