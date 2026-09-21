package web

import (
	"embed"
	"html/template"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/app.css
var appCSS string

//go:embed static/app.js
var appJS string

func parseTemplates() *template.Template {
	return template.Must(template.ParseFS(templateFS, "templates/*.html"))
}
