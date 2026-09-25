package main

import (
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
)

// Exercise the actual release manifest and its UI consumer together: a new
// manifest with an old downloader or old UI cache slot must fail the build.
func TestPinnedReleaseContract(t *testing.T) {
	b, err := os.ReadFile("../../idvLoginComponent.json")
	if err != nil {
		t.Fatal(err)
	}
	var m manifest
	if err = json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	if err = validatePinned(m); err != nil {
		t.Fatal(err)
	}
	ui, err := os.ReadFile("../../playerLauncherApp/Sources/ToolboxModels.swift")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?s)enum IdvLoginRelease\s*\{\s*static let version = "([^"]+)"`)
	match := re.FindSubmatch(ui)
	if len(match) != 2 || string(match[1]) != m.Version {
		t.Fatal("UI and pinned component versions disagree")
	}
	bad := m
	bad.SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
	if validatePinned(bad) == nil {
		t.Fatal("substituted payload digest accepted")
	}
	bad = m
	bad.DownloadURL = "https://github.com/another-owner/another-repo/releases/download/v6.3.0/asset"
	if validatePinned(bad) == nil {
		t.Fatal("different GitHub release accepted")
	}
}

func payload() []byte {
	b := make([]byte, 4096)
	copy(b, []byte{0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0})
	for i := 8; i < len(b); i++ {
		b[i] = byte(i)
	}
	return b
}
func testManifest(url string, b []byte) manifest {
	h := sha256.Sum256(b)
	return manifest{AssetName: "idv-login-v6.2.3-stable-mac", DownloadURL: url, SHA256: hex.EncodeToString(h[:]), ByteSize: int64(len(b))}
}
func server(t *testing.T, body []byte, mode string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" && mode == "range" {
			var start int
			_, e := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-", &start)
			if e != nil {
				t.Fatal(e)
			}
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(body)-1, len(body)))
			w.Header().Set("Content-Length", fmt.Sprint(len(body)-start))
			w.WriteHeader(206)
			_, _ = w.Write(body[start:])
			return
		}
		if r.Header.Get("Range") != "" && mode == "bad" {
			w.Header().Set("Content-Range", "bytes 0-1/2")
			w.WriteHeader(206)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		_, _ = w.Write(body)
	}))
}

func TestFullCacheAndLegacy(t *testing.T) {
	b := payload()
	root := t.TempDir()
	cache := filepath.Join(root, "6.2.3")
	if err := os.Mkdir(cache, 0700); err != nil {
		t.Fatal(err)
	}
	m := testManifest("http://unused", b)
	if err := os.WriteFile(filepath.Join(cache, m.AssetName), b, 0600); err != nil {
		t.Fatal(err)
	}
	got, e := download(m, cache, &http.Client{})
	if e != nil || got == "" {
		t.Fatalf("%v %q", e, got)
	}
	root = t.TempDir()
	cache = filepath.Join(root, "6.2.3")
	old := filepath.Join(root, "123e4567-e89b-12d3-a456-426614174000")
	if err := os.Mkdir(old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, m.AssetName), b, 0600); err != nil {
		t.Fatal(err)
	}
	got, e = download(m, cache, &http.Client{})
	if e != nil {
		t.Fatal(e)
	}
	if e = regularArm64(got, m); e != nil {
		t.Fatal(e)
	}
}

func TestCompletePartialPublishesWithoutNetwork(t *testing.T) {
	b := payload()
	cache := filepath.Join(t.TempDir(), "6.2.3")
	if err := os.Mkdir(cache, 0700); err != nil {
		t.Fatal(err)
	}
	m := testManifest("http://must-not-be-used.invalid", b)
	partial := filepath.Join(cache, m.AssetName+".partial")
	if err := os.WriteFile(partial, b, 0600); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("complete partial unexpectedly reached the network")
		return nil, nil
	})}
	got, err := download(m, cache, client)
	if err != nil {
		t.Fatal(err)
	}
	if err = regularArm64(got, m); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Lstat(partial); !os.IsNotExist(err) {
		t.Fatalf("complete partial was not atomically published: %v", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestRangeAndFallback(t *testing.T) {
	b := payload()
	s := server(t, b, "range")
	defer s.Close()
	m := testManifest(s.URL, b)
	cache := t.TempDir()
	if err := os.WriteFile(filepath.Join(cache, m.AssetName+".partial"), b[:100], 0600); err != nil {
		t.Fatal(err)
	}
	if _, e := download(m, cache, s.Client()); e != nil {
		t.Fatal(e)
	}
	s = server(t, b, "full")
	defer s.Close()
	m = testManifest(s.URL, b)
	cache = t.TempDir()
	if err := os.WriteFile(filepath.Join(cache, m.AssetName+".partial"), b[:100], 0600); err != nil {
		t.Fatal(err)
	}
	if _, e := download(m, cache, s.Client()); e != nil {
		t.Fatal(e)
	}
}
func TestBadRangeHashAndLock(t *testing.T) {
	b := payload()
	s := server(t, b, "bad")
	defer s.Close()
	m := testManifest(s.URL, b)
	cache := t.TempDir()
	_ = os.WriteFile(filepath.Join(cache, m.AssetName+".partial"), b[:10], 0600)
	if _, e := download(m, cache, s.Client()); e == nil {
		t.Fatal("bad range accepted")
	}
	bad := append([]byte(nil), b...)
	bad[100] ^= 1
	s = server(t, bad, "full")
	defer s.Close()
	m = testManifest(s.URL, b)
	cache = t.TempDir()
	if _, e := download(m, cache, s.Client()); e == nil {
		t.Fatal("bad hash accepted")
	}
	if _, e := os.Stat(filepath.Join(cache, m.AssetName+".partial")); !os.IsNotExist(e) {
		t.Fatal("bad partial retained")
	}
	l, e := lockCache(cache)
	if e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	done := make(chan struct{})
	go func() {
		defer wg.Done()
		x, e := lockCache(cache)
		if e == nil {
			unlock(x)
			close(done)
		}
	}()
	select {
	case <-done:
		t.Fatal("lock not exclusive")
	default:
	}
	unlock(l)
	wg.Wait()
	select {
	case <-done:
	default:
		t.Fatal("lock not released")
	}
}

// ── 离线载荷（--payload）────────────────────────────────────────────────────────
// 契约：gzip 只用来绕开 codesign 对裸 Mach-O 的重签；解压产物仍须逐字节通过
// 大小/哈希/arm64 magic 校验，失败 fail closed 并清理 .partial，绝不回退联网。

func gzipFixture(t *testing.T, input []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "idv-login-6.3.0.gz")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := gzip.NewWriter(file)
	if _, err = writer.Write(input); err != nil {
		t.Fatal(err)
	}
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func offlineClient(t *testing.T) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("offline payload fell back to the network")
		return nil, nil
	})}
}

func TestParseArgsKeepsLegacyFormAndAcceptsPayload(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		payload string
		ok      bool
	}{
		{"legacy positional", []string{"m.json", "/cache"}, "", true},
		{"separate payload", []string{"m.json", "/cache", "--payload", "/payload.gz"}, "/payload.gz", true},
		{"inline payload", []string{"m.json", "/cache", "--payload=/payload.gz"}, "/payload.gz", true},
		{"missing arguments", []string{"m.json"}, "", false},
		{"dangling flag", []string{"m.json", "/cache", "--payload"}, "", false},
		{"empty payload", []string{"m.json", "/cache", "--payload", ""}, "", false},
		{"unknown extra", []string{"m.json", "/cache", "extra"}, "", false},
		{"unknown flag", []string{"m.json", "/cache", "--other", "/x"}, "", false},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifestPath, cache, payload, err := parseArgs(testCase.args)
			if (err == nil) != testCase.ok {
				t.Fatalf("accepted=%v want %v (err=%v)", err == nil, testCase.ok, err)
			}
			if !testCase.ok {
				return
			}
			if manifestPath != "m.json" || cache != "/cache" || payload != testCase.payload {
				t.Fatalf("got manifest=%q cache=%q payload=%q", manifestPath, cache, payload)
			}
		})
	}
}

func TestOfflinePayloadDecompressesAndVerifiesWithoutNetwork(t *testing.T) {
	content := payload()
	cache := t.TempDir()
	m := testManifest("http://must-not-be-used.invalid", content)
	archive := gzipFixture(t, content)
	oldStderr := os.Stderr
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = writePipe
	got, acquireErr := acquire(m, cache, offlineClient(t), archive)
	_ = writePipe.Close()
	os.Stderr = oldStderr
	stderrBytes, _ := io.ReadAll(readPipe)
	_ = readPipe.Close()
	if acquireErr != nil {
		t.Fatalf("offline payload install failed: %v", acquireErr)
	}
	if got != filepath.Join(cache, m.AssetName) {
		t.Fatalf("unexpected final path %q", got)
	}
	if err = regularArm64(got, m); err != nil {
		t.Fatalf("published component does not verify: %v", err)
	}
	info, err := os.Stat(got)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("published mode = %v (err=%v), want 0600", info.Mode().Perm(), err)
	}
	if _, err = os.Lstat(got + ".partial"); !os.IsNotExist(err) {
		t.Fatalf("partial file survived a successful install: %v", err)
	}
	want := `{"schemaVersion":1,"phase":"verifying","bytesWritten":1,"totalBytesExpected":1}`
	if !strings.Contains(string(stderrBytes), want) {
		t.Fatalf("verifying progress line missing from %q", string(stderrBytes))
	}
}

func TestOfflinePayloadReusesVerifiedFinal(t *testing.T) {
	content := payload()
	cache := t.TempDir()
	m := testManifest("http://must-not-be-used.invalid", content)
	final := filepath.Join(cache, m.AssetName)
	if err := os.WriteFile(final, content, 0600); err != nil {
		t.Fatal(err)
	}
	// An absent archive proves the verified final file short-circuits extraction.
	got, err := acquire(m, cache, offlineClient(t), filepath.Join(t.TempDir(), "absent.gz"))
	if err != nil {
		t.Fatalf("verified final file was not reused: %v", err)
	}
	if got != final {
		t.Fatalf("reused %q, want %q", got, final)
	}
}

func TestOfflinePayloadFailsClosedAndCleansPartial(t *testing.T) {
	content := payload()
	mutated := append([]byte(nil), content...)
	mutated[100] ^= 1
	link := filepath.Join(t.TempDir(), "linked.gz")
	if err := os.Symlink(gzipFixture(t, content), link); err != nil {
		t.Fatal(err)
	}
	raw := filepath.Join(t.TempDir(), "raw.gz")
	if err := os.WriteFile(raw, []byte("not a gzip stream"), 0600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name    string
		payload string
	}{
		{"missing archive", filepath.Join(t.TempDir(), "absent.gz")},
		{"not gzip", raw},
		{"symlinked archive", link},
		{"truncated artefact", gzipFixture(t, content[:len(content)-1])},
		{"hash mismatch", gzipFixture(t, mutated)},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			cache := t.TempDir()
			m := testManifest("http://must-not-be-used.invalid", content)
			if _, err := acquire(m, cache, offlineClient(t), testCase.payload); err == nil {
				t.Fatal("invalid offline payload was accepted")
			}
			final := filepath.Join(cache, m.AssetName)
			if _, err := os.Lstat(final); !os.IsNotExist(err) {
				t.Fatalf("failed payload published the final component: %v", err)
			}
			if _, err := os.Lstat(final + ".partial"); !os.IsNotExist(err) {
				t.Fatalf("failed payload left a .partial behind: %v", err)
			}
		})
	}
}

func TestWithoutPayloadStillDownloadsOverNetwork(t *testing.T) {
	content := payload()
	server := server(t, content, "full")
	defer server.Close()
	m := testManifest(server.URL, content)
	cache := t.TempDir()
	got, err := acquire(m, cache, server.Client(), "")
	if err != nil {
		t.Fatalf("online path failed: %v", err)
	}
	if err = regularArm64(got, m); err != nil {
		t.Fatalf("downloaded component does not verify: %v", err)
	}
}
