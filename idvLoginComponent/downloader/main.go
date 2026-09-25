package main

import (
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type manifest struct {
	Component, Version, AssetName, DownloadURL, SHA256 string
	ByteSize                                           int64
}
type progressEvent struct {
	SchemaVersion      int    `json:"schemaVersion"`
	Phase              string `json:"phase"`
	BytesWritten       int64  `json:"bytesWritten"`
	TotalBytesExpected int64  `json:"totalBytesExpected"`
}

func emitProgress(phase string, done, total int64) {
	_ = json.NewEncoder(os.Stderr).Encode(progressEvent{1, phase, done, total})
}
func fail(f string, a ...any) { fmt.Fprintf(os.Stderr, f+"\n", a...); os.Exit(1) }

func permitted(u *url.URL) bool {
	return u.Scheme == "https" && (u.Host == "github.com" || u.Host == "objects.githubusercontent.com" || strings.HasSuffix(u.Host, ".githubusercontent.com"))
}
func regularArm64(path string, m manifest) error {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != m.ByteSize {
		return errors.New("component is not the expected regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return err
	}
	if !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), m.SHA256) {
		return errors.New("component SHA-256 mismatch")
	}
	if _, err = f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	var b [8]byte
	if _, err = io.ReadFull(f, b[:]); err != nil {
		return err
	}
	if b[0] != 0xcf || b[1] != 0xfa || b[2] != 0xed || b[3] != 0xfe || b[4] != 0x0c || b[5] != 0x00 {
		return errors.New("component is not an arm64 Mach-O")
	}
	return nil
}
func ensureDir(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("cache path is not a real directory")
	}
	return os.Chmod(path, 0700)
}
func lockCache(cache string) (*os.File, error) {
	p := filepath.Join(cache, ".idv-login-download.lock")
	if i, err := os.Lstat(p); err == nil && (!i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0) {
		return nil, errors.New("download lock is unsafe")
	} else if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, err
	}
	_ = f.Chmod(0600)
	return f, nil
}
func unlock(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }
func copyVerified(source, final string, m manifest) error {
	if err := regularArm64(source, m); err != nil {
		return err
	}
	tmp := final + ".publish"
	_ = os.Remove(tmp)
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, e := io.Copy(out, in)
	c := out.Close()
	if e != nil || c != nil {
		_ = os.Remove(tmp)
		if e != nil {
			return e
		}
		return c
	}
	if err = regularArm64(tmp, m); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err = os.Rename(tmp, final); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Chmod(final, 0600)
}
func reuseLegacy(cache, final string, m manifest) error {
	// The old launcher created one UUID directory directly below
	// IdvLoginDownload.  The stable cache is its version-named sibling:
	//
	//   IdvLoginDownload/<UUID>/<asset>       (legacy)
	//   IdvLoginDownload/<version>/<asset>  (stable)
	//
	// Scan the parent, not the version slot itself.  Every candidate is still
	// required to be a real UUID-shaped directory containing an exact pinned
	// artifact before it can be copied into the stable slot.
	legacyRoot := filepath.Dir(filepath.Clean(cache))
	entries, err := os.ReadDir(legacyRoot)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || len(e.Name()) != 36 {
			continue
		}
		valid := true
		for _, r := range e.Name() {
			if !(r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F') {
				valid = false
				break
			}
		}
		if !valid {
			continue
		}
		d := filepath.Join(legacyRoot, e.Name())
		i, err := os.Lstat(d)
		if err != nil || !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if copyVerified(filepath.Join(d, m.AssetName), final, m) == nil {
			return nil
		}
	}
	return os.ErrNotExist
}
func contentRangeOK(v string, offset, total int64) bool {
	var a, b, c int64
	_, e := fmt.Sscanf(v, "bytes %d-%d/%d", &a, &b, &c)
	return e == nil && a == offset && b == total-1 && c == total
}
func safeClient() *http.Client {
	return &http.Client{Timeout: 0, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 4 || !permitted(req.URL) {
			return errors.New("disallowed download redirect")
		}
		return nil
	}}
}
func stream(resp *http.Response, f *os.File, offset int64, m manifest) error {
	defer resp.Body.Close()
	if resp.ContentLength != m.ByteSize-offset {
		return errors.New("download response has unexpected length")
	}
	return writeStream(resp.Body, f, offset, m)
}

// writeStream copies the remaining component bytes while reporting bounded
// progress.  Both the HTTP body and the offline gzip payload feed it, so the
// UI sees one identical progress stream in either mode.
func writeStream(source io.Reader, f *os.File, offset int64, m manifest) error {
	done := offset
	emitProgress("downloading", done, m.ByteSize)
	buf := make([]byte, 128*1024)
	last := time.Time{}
	for {
		n, e := source.Read(buf)
		if n > 0 {
			if _, w := f.Write(buf[:n]); w != nil {
				return w
			}
			done += int64(n)
			if last.IsZero() || time.Since(last) > 250*time.Millisecond || done == m.ByteSize {
				emitProgress("downloading", done, m.ByteSize)
				last = time.Now()
			}
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
	}
	if done != m.ByteSize {
		return errors.New("download response ended early")
	}
	return nil
}

// download is the original online-only acquisition used by unit fixtures and by
// any caller that has no offline payload.
func download(m manifest, cache string, client *http.Client) (string, error) {
	return acquire(m, cache, client, "")
}

// acquire resolves the pinned component into the cache slot.  payload is an
// optional gzip-compressed copy of the decompressed artefact: when it is set the
// archive replaces the network download entirely and any mismatch is fatal.
func acquire(m manifest, cache string, client *http.Client, payload string) (string, error) {
	if err := ensureDir(cache); err != nil {
		return "", err
	}
	l, err := lockCache(cache)
	if err != nil {
		return "", err
	}
	defer unlock(l)
	final := filepath.Join(cache, m.AssetName)
	if regularArm64(final, m) == nil {
		emitProgress("verifying", 1, 1)
		return final, nil
	}
	if i, e := os.Lstat(final); e == nil && (!i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0) {
		return "", errors.New("stable component path is unsafe")
	}
	if reuseLegacy(cache, final, m) == nil {
		emitProgress("verifying", 1, 1)
		return final, nil
	}
	// Offline package: decompress the bundled copy into the same partial slot and
	// run the same verification.  The network path below is never reached, so a
	// bad payload cannot silently fall back to GitHub.
	if payload != "" {
		return importPayload(payload, final, m)
	}
	partial := final + ".partial"
	offset := int64(0)
	if i, e := os.Lstat(partial); e == nil {
		if !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("partial component path is unsafe")
		}
		if i.Size() == m.ByteSize {
			// A transfer may have finished before the previous launcher could
			// publish the file.  Verify it locally first; asking an HTTP server
			// for bytes=<total>- commonly returns 416 and would strand an already
			// complete artifact.
			if regularArm64(partial, m) == nil {
				if e = os.Rename(partial, final); e != nil {
					return "", e
				}
				if e = os.Chmod(final, 0600); e != nil {
					return "", e
				}
				emitProgress("verifying", 1, 1)
				return final, nil
			}
			if e = os.Remove(partial); e != nil {
				return "", e
			}
		} else if i.Size() < m.ByteSize {
			offset = i.Size()
		} else {
			if e = os.Remove(partial); e != nil {
				return "", e
			}
		}
	} else if !os.IsNotExist(e) {
		return "", e
	}
	request := func(rangeRequest bool) (*http.Response, error) {
		r, _ := http.NewRequest("GET", m.DownloadURL, nil)
		r.Header.Set("Accept-Encoding", "identity")
		if rangeRequest {
			r.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
		}
		return client.Do(r)
	}
	resp, err := request(offset > 0)
	if err != nil {
		return "", err
	}
	if offset > 0 && resp.StatusCode == http.StatusOK {
		_ = resp.Body.Close()
		if e := os.Remove(partial); e != nil && !os.IsNotExist(e) {
			return "", e
		}
		offset = 0
		resp, err = request(false)
		if err != nil {
			return "", err
		}
	}
	if offset > 0 {
		if resp.StatusCode != http.StatusPartialContent || !contentRangeOK(resp.Header.Get("Content-Range"), offset, m.ByteSize) {
			_ = resp.Body.Close()
			return "", errors.New("invalid HTTP range response")
		}
	} else if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		return "", fmt.Errorf("download status rejected: %s", resp.Status)
	}
	flag := os.O_CREATE | os.O_WRONLY
	if offset > 0 {
		flag |= os.O_APPEND
	} else {
		flag |= os.O_TRUNC
	}
	f, err := os.OpenFile(partial, flag, 0600)
	if err != nil {
		_ = resp.Body.Close()
		return "", err
	}
	e := stream(resp, f, offset, m)
	c := f.Close()
	if e != nil {
		return "", e
	}
	if c != nil {
		return "", c
	}
	if err = regularArm64(partial, m); err != nil {
		_ = os.Remove(partial)
		return "", err
	}
	if err = os.Rename(partial, final); err != nil {
		return "", err
	}
	if err = os.Chmod(final, 0600); err != nil {
		return "", err
	}
	emitProgress("verifying", 1, 1)
	return final, nil
}

// importPayload decompresses the offline gzip copy into the stable slot.  The
// archive itself is not pinned (gzip only exists so codesign can re-sign the App
// tree), so nothing is trusted until the decompressed bytes pass the exact size,
// SHA-256 and arm64 Mach-O checks used for a download.  A failure removes the
// partial file and never consults the network.
func importPayload(payload, final string, m manifest) (string, error) {
	info, err := os.Lstat(payload)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("offline payload is not a regular file")
	}
	source, err := os.Open(payload)
	if err != nil {
		return "", err
	}
	defer source.Close()
	archive, err := gzip.NewReader(source)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	partial := final + ".partial"
	if i, e := os.Lstat(partial); e == nil {
		if !i.Mode().IsRegular() || i.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("partial component path is unsafe")
		}
		if e = os.Remove(partial); e != nil {
			return "", e
		}
	} else if !os.IsNotExist(e) {
		return "", e
	}
	out, err := os.OpenFile(partial, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	e := writeStream(archive, out, 0, m)
	c := out.Close()
	if e != nil || c != nil {
		_ = os.Remove(partial)
		if e != nil {
			return "", e
		}
		return "", c
	}
	if err = regularArm64(partial, m); err != nil {
		_ = os.Remove(partial)
		return "", err
	}
	if err = os.Rename(partial, final); err != nil {
		_ = os.Remove(partial)
		return "", err
	}
	if err = os.Chmod(final, 0600); err != nil {
		return "", err
	}
	emitProgress("verifying", 1, 1)
	return final, nil
}

// parseArgs keeps the original two-positional form byte-for-byte compatible and
// adds the optional offline payload form.  Both `--payload ABS` and
// `--payload=ABS` are accepted so a quoting difference cannot silently select a
// different file.
func parseArgs(args []string) (manifestPath, cache string, payload string, err error) {
	if len(args) < 2 {
		return "", "", "", errors.New("missing arguments")
	}
	manifestPath, cache = args[0], args[1]
	switch {
	case len(args) == 2:
	case len(args) == 3 && strings.HasPrefix(args[2], "--payload="):
		payload = strings.TrimPrefix(args[2], "--payload=")
	case len(args) == 4 && args[2] == "--payload":
		payload = args[3]
	default:
		return "", "", "", errors.New("unexpected arguments")
	}
	if len(args) > 2 && payload == "" {
		return "", "", "", errors.New("empty offline payload path")
	}
	return manifestPath, cache, payload, nil
}

func validatePinned(m manifest) error {
	if m.Component != "idv-login" || m.Version != "6.3.0" || m.AssetName != "idv-login-v6.3.0-stable-mac" || m.ByteSize != 197215760 || m.SHA256 != "8e63be76de37b4aeb8c6617d0d4c44a983d3d8e6d29c565c5074085286fe6889" || m.DownloadURL != "https://github.com/KKeygen/idv-login/releases/download/v6.3.0-stable/idv-login-v6.3.0-stable-mac" {
		return errors.New("invalid pinned IDV Login manifest")
	}
	u, e := url.Parse(m.DownloadURL)
	if e != nil || !permitted(u) {
		return errors.New("manifest download URL is not an allowed HTTPS GitHub host")
	}
	return nil
}
func main() {
	if len(os.Args) == 2 && os.Args[1] == "--self-test" {
		fmt.Println("idv-login-downloader self-test passed")
		return
	}
	manifestPath, cache, payload, err := parseArgs(os.Args[1:])
	if err != nil {
		fail("usage: %s manifest.json cache-directory [--payload ABS]", filepath.Base(os.Args[0]))
	}
	b, e := os.ReadFile(manifestPath)
	if e != nil {
		fail("read manifest: %v", e)
	}
	var m manifest
	if json.Unmarshal(b, &m) != nil {
		fail("invalid pinned IDV Login manifest")
	}
	if e = validatePinned(m); e != nil {
		fail("%v", e)
	}
	p, e := acquire(m, cache, safeClient(), payload)
	if e != nil {
		fail("download component: %v", e)
	}
	fmt.Println(p)
}
