package main

import (
	"os"
	"net"
	"net/http"

	"github.com/labstack/echo"
)

func main() {
	e := echo.New()
	e.GET("/", func(c echo.Context) error {
		return c.String(http.StatusOK, "Hello, World")
	})

	socket_path := "/var/run/glaaki/glaaki.sock"
	os.Remove(socket_path)

	l, err := net.Listen("unix", socket_path)
	if err != nil {
		e.Logger.Fatal(err)
	}

	err = os.Chmod(socket_path, 0500)
	if err != nil {
		e.Logger.Fatal(err)
	}

	e.Listener = l
	e.Logger.Fatal(e.Start(""))
}
