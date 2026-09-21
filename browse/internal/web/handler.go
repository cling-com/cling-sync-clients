// The browse UI: every view is a route on the handler plus an HTML
// template, served identically over real HTTP (cmd/cling-browse) and the
// apps' embedded callback (package browse).
package web

import (
	"errors"
	"fmt"
	"html/template"
	"mime"
	"net/http"
	"net/url"
	"strconv"

	"github.com/cling-com/cling-sync/lib"
	"github.com/flunderpero/cling-sync-clients/browse/internal/session"
)

type entryView struct {
	Name          string
	PathString    string
	DownloadHref  template.URL
	SymlinkTarget string
	IsDir         bool
	IsSymlink     bool
	SizeHuman     string
	MTimeHuman    string
}

type dirView struct {
	Entries []entryView
}

type pageView struct {
	Title string
	CSS   template.CSS
	JS    template.JS
	Root  dirView
}

type handler struct {
	session   *session.Session
	templates *template.Template
}

// Return the full UI as an `http.Handler`.
//
// cmd/cling-browse mounts it on a real server, the apps drive it through the
// browse package.
func NewHandler(s *session.Session) http.Handler {
	h := &handler{s, parseTemplates()}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", h.page)
	mux.HandleFunc("GET /dir", h.dir)
	mux.HandleFunc("GET /download", h.download)
	return securityHeaders(mux)
}

func (h *handler) page(w http.ResponseWriter, r *http.Request) {
	entries, err := h.session.ListDir(r.Context(), lib.Path{})
	if err != nil {
		writeError(w, err)
		return
	}
	view := pageView{
		Title: "Cling Sync",
		CSS:   template.CSS(appCSS), //nolint:gosec // Embedded static/app.css, not request data.
		JS:    template.JS(appJS),   //nolint:gosec // Embedded static/app.js, not request data.
		Root:  dirView{Entries: toEntryViews(entries)},
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := h.templates.ExecuteTemplate(w, "layout.html", view); err != nil {
		writeError(w, err)
	}
}

func (h *handler) dir(w http.ResponseWriter, r *http.Request) {
	path, err := session.ParsePath(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, err)
		return
	}
	entries, err := h.session.ListDir(r.Context(), path)
	if err != nil {
		writeError(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := h.templates.ExecuteTemplate(w, "dir", dirView{Entries: toEntryViews(entries)}); err != nil {
		writeError(w, err)
	}
}

func (h *handler) download(w http.ResponseWriter, r *http.Request) {
	path, err := session.ParsePath(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, err)
		return
	}
	entry, err := h.session.ResolveFile(r.Context(), path)
	if err != nil {
		writeError(w, err)
		return
	}
	filename := entry.Path.Base().String()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(entry.Metadata.Size, 10))
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": filename}))
	// Errors past this point cannot change the response code anymore, the
	// broken connection is the only signal left.
	_ = h.session.StreamFile(r.Context(), w, entry)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set(
			"Content-Security-Policy",
			"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'",
		)
		next.ServeHTTP(w, r)
	})
}

func writeError(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	switch {
	case errors.Is(err, session.ErrNotFound):
		status = http.StatusNotFound
	case errors.Is(err, session.ErrBadPath):
		status = http.StatusBadRequest
	}
	http.Error(w, err.Error(), status)
}

func toEntryViews(entries []*lib.RevisionEntry) []entryView {
	views := make([]entryView, 0, len(entries))
	for _, entry := range entries {
		view := entryView{ //nolint:exhaustruct
			Name:       entry.Path.Base().String(),
			PathString: entry.Path.String(),
			IsDir:      entry.Metadata.FileMode.IsDir(),
			IsSymlink:  entry.Metadata.FileMode.IsSymlink(),
		}
		switch {
		case view.IsSymlink:
			view.SymlinkTarget = entry.Metadata.SymLinkTarget.String()
		case !view.IsDir:
			query := url.Values{"path": []string{entry.Path.String()}}
			view.DownloadHref = template.URL("download?" + query.Encode()) //nolint:gosec // Query-encoded above.
			view.SizeHuman = humanSize(entry.Metadata.Size)
			view.MTimeHuman = entry.Metadata.MTime().Format("2006-01-02 15:04")
		}
		views = append(views, view)
	}
	return views
}

func humanSize(size int64) string {
	const unit = 1024
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}
	value := float64(size)
	for _, suffix := range []string{"KiB", "MiB", "GiB", "TiB"} {
		value /= unit
		if value < unit {
			return fmt.Sprintf("%.1f %s", value, suffix)
		}
	}
	return fmt.Sprintf("%.1f PiB", float64(size)/unit/unit/unit/unit/unit)
}
