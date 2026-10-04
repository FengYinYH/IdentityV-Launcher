package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
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

// ── 离线载荷（--payload-image，内嵌只读磁盘映像）────────────────────────────────
// 契约：上游 Mach-O 不重签、不改字节，装进磁盘映像以绕开 notary 对裸 Mach-O 的检查。
// 取出的产物仍须逐字节通过大小/哈希/arm64 magic 校验；失败 fail closed、清理
// .partial、必须 detach 不留挂载点，且绝不回退联网。

func offlineClient(t *testing.T) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("offline payload image fell back to the network")
		return nil, nil
	})}
}

// imageFixture builds a real disk image whose volume root holds exactly what
// prepare writes.  The shipped payload is UDZO ("UDZO"); the fail-closed matrix
// uses UDRW because it is faster to build and exercises the identical
// hdiutil attach/detach code path.  It mirrors runtimeBootstrap's buildRuntimeDMG.
func imageFixture(t *testing.T, format string, prepare func(source string)) string {
	t.Helper()
	if info, err := os.Stat("/usr/bin/hdiutil"); err != nil || info.Mode()&0111 == 0 {
		t.Skip("hdiutil is required for the offline payload image fixture")
	}
	source := t.TempDir()
	prepare(source)
	image := filepath.Join(t.TempDir(), "IdvLoginPayload.dmg")
	output, err := exec.Command("/usr/bin/hdiutil", "create", "-quiet", "-format", format,
		"-volname", "IdvLoginPayload", "-srcfolder", source, image).CombinedOutput()
	if err != nil {
		t.Fatalf("cannot build DMG fixture: %v: %s", err, output)
	}
	return image
}

func mustWriteFixture(t *testing.T, directory, name string, content []byte) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, name), content, 0644); err != nil {
		t.Fatal(err)
	}
}

// artefactImage is the well-formed packaging: exactly one visible regular file
// carrying the untouched artefact.
func artefactImage(t *testing.T, format, name string, content []byte) string {
	t.Helper()
	return imageFixture(t, format, func(source string) { mustWriteFixture(t, source, name, content) })
}

// scopeTempRoot points this test process at a private TMPDIR.  The helper creates
// its mountpoint under os.TempDir(), so without this two concurrent runs of the
// same package would see each other's live mountpoints and appear to leak.
func scopeTempRoot(t *testing.T) string {
	t.Helper()
	if info, err := os.Stat("/usr/bin/hdiutil"); err != nil || info.Mode()&0111 == 0 {
		t.Skip("hdiutil is required for the offline payload image fixture")
	}
	// macOS rejects hdiutil mountpoints on some external APFS volumes. Keep
	// these small image-test fixtures in an isolated, automatically cleaned
	// system temporary directory; production paths and build caches are unchanged.
	root, err := os.MkdirTemp("/private/tmp", "idv-login-image-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(root); err != nil {
			t.Errorf("remove image-test temporary directory: %v", err)
		}
	})
	t.Setenv("TMPDIR", root)
	return root
}

// assertNoStaleMounts fails when a payload mountpoint survived in this test's
// private TMPDIR, which is how a missed hdiutil detach surfaces.
func assertNoStaleMounts(t *testing.T) {
	t.Helper()
	stale, err := filepath.Glob(filepath.Join(os.TempDir(), "idv-login-payload-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(stale) != 0 {
		t.Fatalf("payload mountpoints were not cleaned up: %v", stale)
	}
}

func fixtureHashHex(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

// offlineDocument models the packaged OfflinePayloads/offlinePayloads.json.  The
// upstream fields must equal the component lock, while offlineByteCount /
// offlineSha256 describe the re-signed artefact that actually ships inside the
// image.
func offlineDocument(upstream manifest, offline []byte) map[string]any {
	return map[string]any{
		"schemaVersion": 1,
		"kind":          "identityv-offline-payloads",
		"idvLogin": map[string]any{
			"file":             "idv-login-" + upstream.Version + ".dmg",
			"version":          upstream.Version,
			"assetName":        upstream.AssetName,
			"byteCount":        upstream.ByteSize,
			"sha256":           upstream.SHA256,
			"offlineByteCount": len(offline),
			"offlineSha256":    fixtureHashHex(offline),
		},
	}
}

func writeOfflineDocument(t *testing.T, document map[string]any) string {
	t.Helper()
	encoded, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return writeOfflineRaw(t, string(append(encoded, '\n')))
}

func writeOfflineRaw(t *testing.T, raw string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "offlinePayloads.json")
	if err := os.WriteFile(path, []byte(raw), 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

// offlineFixture is the packaged shape: an image holding the re-signed bytes plus
// a manifest whose offline expectation matches those bytes while its upstream
// fields still match the locked release.  Re-signing normally changes the size,
// so the fixture grows the artefact as well.
func offlineFixture(t *testing.T) (upstream manifest, offline []byte, image, document string) {
	t.Helper()
	upstreamBytes := payload()
	upstream = testManifest("http://must-not-be-used.invalid", upstreamBytes)
	upstream.Version = "6.2.3"
	offline = append(append([]byte(nil), upstreamBytes...), bytes.Repeat([]byte{7}, 8192)...)
	image = artefactImage(t, "UDZO", upstream.AssetName, offline)
	document = writeOfflineDocument(t, offlineDocument(upstream, offline))
	return upstream, offline, image, document
}

func effectiveManifest(upstream manifest, offline []byte) manifest {
	effective := upstream
	effective.ByteSize = int64(len(offline))
	effective.SHA256 = fixtureHashHex(offline)
	return effective
}

func TestParseArgsKeepsLegacyFormAndAcceptsPairedPayload(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		image    string
		document string
		ok       bool
	}{
		{"legacy positional", []string{"m.json", "/cache"}, "", "", true},
		{"paired separate", []string{"m.json", "/cache", "--payload-image", "/p.dmg", "--payload-manifest", "/o.json"}, "/p.dmg", "/o.json", true},
		{"paired inline", []string{"m.json", "/cache", "--payload-image=/p.dmg", "--payload-manifest=/o.json"}, "/p.dmg", "/o.json", true},
		{"paired reversed order", []string{"m.json", "/cache", "--payload-manifest", "/o.json", "--payload-image", "/p.dmg"}, "/p.dmg", "/o.json", true},
		{"image only", []string{"m.json", "/cache", "--payload-image", "/p.dmg"}, "", "", false},
		{"manifest only", []string{"m.json", "/cache", "--payload-manifest", "/o.json"}, "", "", false},
		{"image only inline", []string{"m.json", "/cache", "--payload-image=/p.dmg"}, "", "", false},
		{"missing arguments", []string{"m.json"}, "", "", false},
		{"dangling image", []string{"m.json", "/cache", "--payload-image"}, "", "", false},
		{"empty image", []string{"m.json", "/cache", "--payload-image", ""}, "", "", false},
		{"duplicate image", []string{"m.json", "/cache", "--payload-image", "/a.dmg", "--payload-image", "/b.dmg", "--payload-manifest", "/o.json"}, "", "", false},
		{"retired gzip form", []string{"m.json", "/cache", "--payload", "/p.gz"}, "", "", false},
		{"retired gzip inline", []string{"m.json", "/cache", "--payload=/p.gz"}, "", "", false},
		{"unknown extra", []string{"m.json", "/cache", "extra"}, "", "", false},
		{"unknown flag", []string{"m.json", "/cache", "--other", "/x"}, "", "", false},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifestPath, cache, image, document, err := parseArgs(testCase.args)
			if (err == nil) != testCase.ok {
				t.Fatalf("accepted=%v want %v (err=%v)", err == nil, testCase.ok, err)
			}
			if !testCase.ok {
				return
			}
			if manifestPath != "m.json" || cache != "/cache" || image != testCase.image || document != testCase.document {
				t.Fatalf("got manifest=%q cache=%q image=%q document=%q", manifestPath, cache, image, document)
			}
		})
	}
}

func TestAcquireRequiresPairedOfflineArguments(t *testing.T) {
	scopeTempRoot(t)
	upstream := testManifest("http://unused", payload())
	upstream.Version = "6.2.3"
	cache := t.TempDir()
	if _, err := acquire(upstream, cache, offlineClient(t), "/tmp/only.dmg", ""); err == nil {
		t.Fatal("accepted an image without its manifest")
	}
	if _, err := acquire(upstream, cache, offlineClient(t), "", "/tmp/only.json"); err == nil {
		t.Fatal("accepted a manifest without its image")
	}
}

func TestRequireSingleArtefactEnforcesPackagingContract(t *testing.T) {
	content := payload()
	m := testManifest("http://unused", content)
	t.Run("single artefact with hidden system entries", func(t *testing.T) {
		mount := t.TempDir()
		mustWriteFixture(t, mount, m.AssetName, content)
		mustWriteFixture(t, mount, ".DS_Store", []byte("finder"))
		if err := os.Mkdir(filepath.Join(mount, ".Trashes"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := requireSingleArtefact(mount, m); err != nil {
			t.Fatalf("valid image rejected: %v", err)
		}
	})
	t.Run("second visible file", func(t *testing.T) {
		mount := t.TempDir()
		mustWriteFixture(t, mount, m.AssetName, content)
		mustWriteFixture(t, mount, "extra.bin", content)
		if requireSingleArtefact(mount, m) == nil {
			t.Fatal("accepted a second visible file")
		}
	})
	t.Run("unexpected name", func(t *testing.T) {
		mount := t.TempDir()
		mustWriteFixture(t, mount, "other.bin", content)
		if requireSingleArtefact(mount, m) == nil {
			t.Fatal("accepted an unexpected filename")
		}
	})
	t.Run("symlinked artefact", func(t *testing.T) {
		mount := t.TempDir()
		// The target is hidden so the symlink stays the only visible entry and
		// this subtest isolates the symlink rejection.
		mustWriteFixture(t, mount, ".target", content)
		if err := os.Symlink(filepath.Join(mount, ".target"), filepath.Join(mount, m.AssetName)); err != nil {
			t.Fatal(err)
		}
		if requireSingleArtefact(mount, m) == nil {
			t.Fatal("accepted a symlinked artefact")
		}
	})
	t.Run("empty image", func(t *testing.T) {
		if requireSingleArtefact(t.TempDir(), m) == nil {
			t.Fatal("accepted an image without the pinned artefact")
		}
	})
}

func TestOfflinePayloadImageInstallsWithoutNetwork(t *testing.T) {
	scopeTempRoot(t)
	upstream, offline, image, document := offlineFixture(t)
	cache := t.TempDir()
	oldStderr := os.Stderr
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = writePipe
	got, acquireErr := acquire(upstream, cache, offlineClient(t), image, document)
	_ = writePipe.Close()
	os.Stderr = oldStderr
	stderrBytes, _ := io.ReadAll(readPipe)
	_ = readPipe.Close()
	if acquireErr != nil {
		t.Fatalf("offline payload image install failed: %v", acquireErr)
	}
	if got != filepath.Join(cache, upstream.AssetName) {
		t.Fatalf("unexpected final path %q", got)
	}
	if err = regularArm64(got, effectiveManifest(upstream, offline)); err != nil {
		t.Fatalf("published component does not verify against the offline expectation: %v", err)
	}
	published, err := os.ReadFile(got)
	if err != nil || fixtureHashHex(published) != fixtureHashHex(offline) {
		t.Fatalf("published bytes are not the re-signed offline artefact: err=%v", err)
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
	assertNoStaleMounts(t)
}

func TestOfflinePayloadExpectationDrivesReuse(t *testing.T) {
	scopeTempRoot(t)
	upstream, offline, image, document := offlineFixture(t)

	t.Run("reuses the verified offline build without mounting", func(t *testing.T) {
		cache := t.TempDir()
		final := filepath.Join(cache, upstream.AssetName)
		if err := os.WriteFile(final, offline, 0600); err != nil {
			t.Fatal(err)
		}
		// A path that cannot be mounted proves the cache check short-circuits.
		got, err := acquire(upstream, cache, offlineClient(t), filepath.Join(t.TempDir(), "absent.dmg"), document)
		if err != nil {
			t.Fatalf("verified offline build was not reused: %v", err)
		}
		if got != final {
			t.Fatalf("reused %q, want %q", got, final)
		}
		assertNoStaleMounts(t)
	})

	t.Run("does not reuse the mismatching upstream build", func(t *testing.T) {
		cache := t.TempDir()
		// The upstream artefact satisfies the upstream lock but not the offline
		// expectation, so it must be replaced by the re-signed build.
		if err := os.WriteFile(filepath.Join(cache, upstream.AssetName), payload(), 0600); err != nil {
			t.Fatal(err)
		}
		got, err := acquire(upstream, cache, offlineClient(t), image, document)
		if err != nil {
			t.Fatalf("re-signed build was not acquired: %v", err)
		}
		published, err := os.ReadFile(got)
		if err != nil || fixtureHashHex(published) != fixtureHashHex(offline) {
			t.Fatalf("upstream build was reused instead of the offline one: err=%v", err)
		}
		assertNoStaleMounts(t)
	})
}

func TestOfflinePayloadImageFailsClosed(t *testing.T) {
	scopeTempRoot(t)
	upstream, offline, goodImage, goodDocument := offlineFixture(t)
	upstreamBytes := payload()
	mutated := append([]byte(nil), offline...)
	mutated[100] ^= 1
	noMagic := append([]byte(nil), offline...)
	for i := 0; i < 8; i++ {
		noMagic[i] = 0
	}
	brokenImage := filepath.Join(t.TempDir(), "broken.dmg")
	if err := os.WriteFile(brokenImage, []byte("this is not a disk image"), 0600); err != nil {
		t.Fatal(err)
	}
	linkedImage := filepath.Join(t.TempDir(), "linked.dmg")
	if err := os.Symlink(artefactImage(t, "UDRW", upstream.AssetName, offline), linkedImage); err != nil {
		t.Fatal(err)
	}
	secondVisible := imageFixture(t, "UDRW", func(source string) {
		mustWriteFixture(t, source, upstream.AssetName, offline)
		mustWriteFixture(t, source, "extra.bin", []byte("extra"))
	})
	unexpectedName := imageFixture(t, "UDRW", func(source string) {
		mustWriteFixture(t, source, "other.bin", offline)
	})
	withDocument := func(mutate func(document map[string]any)) string {
		document := offlineDocument(upstream, offline)
		mutate(document)
		return writeOfflineDocument(t, document)
	}
	assertRejected := func(t *testing.T, image, document string) {
		t.Helper()
		cache := t.TempDir()
		if _, err := acquire(upstream, cache, offlineClient(t), image, document); err == nil {
			t.Fatal("invalid offline payload was accepted")
		}
		final := filepath.Join(cache, upstream.AssetName)
		if _, err := os.Lstat(final); !os.IsNotExist(err) {
			t.Fatalf("failed payload published the final component: %v", err)
		}
		if _, err := os.Lstat(final + ".partial"); !os.IsNotExist(err) {
			t.Fatalf("failed payload left a .partial behind: %v", err)
		}
		assertNoStaleMounts(t)
	}

	imageCases := []struct {
		name     string
		image    string
		document string
	}{
		{"missing image", filepath.Join(t.TempDir(), "absent.dmg"), goodDocument},
		{"not a disk image", brokenImage, goodDocument},
		{"symlinked image", linkedImage, goodDocument},
		{"second visible file", secondVisible, goodDocument},
		{"unexpected filename", unexpectedName, goodDocument},
		{"size mismatch", artefactImage(t, "UDRW", upstream.AssetName, offline[:len(offline)-1]), goodDocument},
		{"hash mismatch", artefactImage(t, "UDRW", upstream.AssetName, mutated), goodDocument},
		{"missing arm64 magic", artefactImage(t, "UDRW", upstream.AssetName, noMagic), writeOfflineDocument(t, offlineDocument(upstream, noMagic))},
		// The manifest matches the upstream lock, but the expectation it carries
		// does not match the bytes inside the image.
		{"offline hash does not match image", goodImage, withDocument(func(document map[string]any) {
			document["idvLogin"].(map[string]any)["offlineSha256"] = fixtureHashHex(upstreamBytes)
		})},
		{"offline size does not match image", goodImage, withDocument(func(document map[string]any) {
			document["idvLogin"].(map[string]any)["offlineByteCount"] = len(offline) + 1
		})},
	}
	for _, testCase := range imageCases {
		t.Run(testCase.name, func(t *testing.T) { assertRejected(t, testCase.image, testCase.document) })
	}

	manifestCases := []struct {
		name     string
		document string
	}{
		{"missing manifest", filepath.Join(t.TempDir(), "absent.json")},
		{"malformed manifest", writeOfflineRaw(t, "{not json")},
		{"wrong kind", withDocument(func(document map[string]any) { document["kind"] = "something-else" })},
		{"wrong schema version", withDocument(func(document map[string]any) { document["schemaVersion"] = 2 })},
		{"asset name mismatch", withDocument(func(document map[string]any) {
			document["idvLogin"].(map[string]any)["assetName"] = "other"
		})},
		{"version mismatch", withDocument(func(document map[string]any) {
			document["idvLogin"].(map[string]any)["version"] = "9.9.9"
		})},
		{"upstream byteCount mismatch", withDocument(func(document map[string]any) {
			document["idvLogin"].(map[string]any)["byteCount"] = upstream.ByteSize + 1
		})},
		{"upstream sha256 mismatch", withDocument(func(document map[string]any) {
			document["idvLogin"].(map[string]any)["sha256"] = strings.Repeat("0", 64)
		})},
		{"missing offline expectation", withDocument(func(document map[string]any) {
			delete(document["idvLogin"].(map[string]any), "offlineByteCount")
			delete(document["idvLogin"].(map[string]any), "offlineSha256")
		})},
	}
	for _, testCase := range manifestCases {
		t.Run(testCase.name, func(t *testing.T) { assertRejected(t, goodImage, testCase.document) })
	}
}

func TestWithoutPayloadStillDownloadsOverNetwork(t *testing.T) {
	content := payload()
	server := server(t, content, "full")
	defer server.Close()
	m := testManifest(server.URL, content)
	cache := t.TempDir()
	got, err := acquire(m, cache, server.Client(), "", "")
	if err != nil {
		t.Fatalf("online path failed: %v", err)
	}
	if err = regularArm64(got, m); err != nil {
		t.Fatalf("downloaded component does not verify: %v", err)
	}
}
