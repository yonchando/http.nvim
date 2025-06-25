package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"

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

	switch args.Method {
	case "GET":
		getRequest()
	case "POST":
		postRequest()
	case "PUT":
		putRequest()
	case "PATCH":
		patchRequest()
	case "DELETE":
		deleteRequest()
	default:
		response := response{
			StatusCode: 500,
			Header:     map[string][]string{},
			Request:    "",
			Content: map[string]string{
				"exception": "http.nvim method not methods.",
				"error":     "Method not support, Could use ",
			},
		}

		response.write()
	}

}
