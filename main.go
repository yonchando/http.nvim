package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/alexflint/go-arg"
)

type Header struct {
	ContentType string `json:"Content-Type"`
	Accept      string `json:"Accept"`
}

var args struct {
	URL    string `arg:"required"`
	Method string `arg:"required"`
	Data   string
	Header string
}

type body []map[string]string

type response struct {
	StatusCode int                 `json:"status_code"`
	Header     map[string][]string `json:"header"`
	Request    string              `json:"request"`
	Content    any                 `json:"body"`
}

func (res *response) setRequest(body io.ReadCloser) *response {
	reader, err := io.ReadAll(body)

	if err != nil {
		res.setStatusCode(500).setContent(err).write()
	}

	res.Request = string(reader)

	return res
}

func (res *response) SetHeader(header map[string][]string) *response {
	res.Header = header
	return res
}

func (res *response) write() {

	result, err := json.Marshal(res)

	if err != nil {
		log.Fatalln(err)
	}

	fmt.Println(string(result))
}

func (res *response) setStatusCode(status_code int) *response {
	res.StatusCode = status_code

	return res
}

func (res *response) setContent(content any) *response {

	res.Content = content

	return res
}

func main() {
	arg.MustParse(&args)

	var header Header

	json.Unmarshal([]byte(args.Header), &header)

	req, err := http.NewRequest(args.Method, args.URL, strings.NewReader(args.Data))

	response := response{
		StatusCode: 200,
		Content:    nil,
	}

	response.setRequest(req.Body)

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	if header.ContentType != "" {
		req.Header.Set("Content-Type", header.ContentType)
		fmt.Println(req.Header.Get("Content-Type"))
	}
	if header.Accept != "" {
		req.Header.Set("Accept", header.Accept)
	}

	client := &http.Client{
		Timeout: time.Second * 3,
	}

	clientRes, err := client.Do(req)

	if err != nil {
		response.setStatusCode(500).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	response.SetHeader(clientRes.Header)

	defer clientRes.Body.Close()

	body, err := io.ReadAll(clientRes.Body)

	if err != nil {
		response.setStatusCode(clientRes.StatusCode).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	var content any
	err = json.Unmarshal(body, &content)

	if err != nil {
		response.setStatusCode(clientRes.StatusCode).setContent(map[string]string{
			"error": err.Error(),
		}).write()
		return
	}

	response.setStatusCode(clientRes.StatusCode).setContent(content).write()
}
