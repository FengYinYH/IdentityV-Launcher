package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
	done := offset
	emitProgress("downloading", done, m.ByteSize)
	buf := make([]byte, 128*1024)
	last := time.Time{}
	for {
		n, e := resp.Body.Read(buf)
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
	return acquire(m, cache, client, "", "")
}

// acquire resolves the pinned component into the cache slot.  payloadImage and
// payloadManifest are the optional packaged offline pair: the image holds the
// re-signed artefact and the manifest records the expectation for exactly those
// bytes.  When present the image replaces the network download entirely and any
// mismatch is fatal.
func acquire(m manifest, cache string, client *http.Client, payloadImage, payloadManifest string) (string, error) {
	if (payloadImage == "") != (payloadManifest == "") {
		return "", errors.New("offline payload image and manifest must be supplied together")
	}
	if payloadManifest != "" {
		expectedBytes, expectedHash, err := readOfflineManifest(payloadManifest, m)
		if err != nil {
			return "", err
		}
		// The caller has already validated the upstream lock with validatePinned.
		// Packaging re-signs idv-login, so the shipped bytes no longer match that
		// lock; a secure timestamp makes the signature non-reproducible, so the
		// expected size/hash can only come from the manifest packaged beside the
		// image.  Overriding here, before any cache or verification decision,
		// keeps regularArm64, copyVerified, reuseLegacy and publication all
		// judged by the same effective expectation.  An upstream build and a
		// re-signed build therefore never satisfy each other and each is
		// acquired again: that is intentional.
		m.ByteSize = expectedBytes
		m.SHA256 = expectedHash
	}
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
	// Offline package: mount the bundled disk image, copy the pinned artefact into
	// the same partial slot and run the same verification.  The network path below
	// is never reached, so a bad image cannot silently fall back to GitHub.
	if payloadImage != "" {
		return importPayloadImage(payloadImage, final, m)
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

// attachDiskImage mounts a read-only offline payload image and returns the
// device node hdiutil reported.  This mirrors runtimeBootstrap/main.go's
// attachDMG; that helper lives in a separate main package, so the small proven
// logic is copied instead of imported.
func attachDiskImage(image, mount string) (string, error) {
	output, err := exec.Command("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cannot mount offline payload image: %s", strings.TrimSpace(string(output)))
	}
	// The volume line also names the mountpoint.  Prefer that device over the
	// outer container: detaching the container can fail while its volume is
	// mounted, which would strand a mounted payload on the host.
	needle := mount
	if resolved, resolveErr := filepath.EvalSymlinks(mount); resolveErr == nil {
		needle = resolved
	}
	fallback := ""
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || !strings.HasPrefix(fields[0], "/dev/disk") {
			continue
		}
		fallback = fields[0]
		if strings.Contains(line, needle) {
			return fields[0], nil
		}
	}
	if fallback == "" {
		return "", errors.New("mounted image did not report a disk")
	}
	return fallback, nil
}

// detachDiskImage ejects the attached image and then removes the private
// mountpoint.  Both steps are retried and the detach is finally forced, so a
// volume that is still busy cannot leave a mounted payload behind.
func detachDiskImage(device, mount string) {
	if device != "" {
		for attempt := 0; attempt < 3; attempt++ {
			if exec.Command("/usr/bin/hdiutil", "detach", device).Run() == nil {
				break
			}
			if exec.Command("/usr/bin/hdiutil", "detach", "-force", device).Run() == nil {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
	for attempt := 0; attempt < 5; attempt++ {
		if err := os.Remove(mount); err == nil || os.IsNotExist(err) {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// requireSingleArtefact enforces the packaging contract: the mounted image must
// hold exactly one non-hidden regular file, and it must be the pinned asset
// name.  Finder and the OS leave synthetic hidden entries such as .DS_Store or
// .Trashes behind, so hidden names are ignored; a second visible file means the
// image was built wrong and must not be trusted.
func requireSingleArtefact(mount string, m manifest) error {
	entries, err := os.ReadDir(mount)
	if err != nil {
		return err
	}
	found := false
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		if found {
			return errors.New("offline payload image contains more than one file")
		}
		if entry.Name() != m.AssetName {
			return fmt.Errorf("offline payload image contains an unexpected file: %s", entry.Name())
		}
		info, err := os.Lstat(filepath.Join(mount, entry.Name()))
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("offline payload artefact is not a regular file")
		}
		found = true
	}
	if !found {
		return errors.New("offline payload image does not contain the pinned artefact")
	}
	return nil
}

// importPayloadImage mounts the bundled read-only disk image, copies out its
// single pinned artefact and verifies it exactly as a download would.  The image
// is packaging scaffolding, not a notarisation loophole: notarisation does
// inspect Mach-O files inside an embedded image, so the artefact was already
// re-signed with this project's Developer ID (hardened runtime + secure
// timestamp) before it went in.  Keeping it inside an image stops the outer
// bundle signing pass from rewriting those bytes, which is what makes the
// packaging-time digest recorded in offlinePayloads.json stable.  The image is
// detached on every path, including failures, and no network is ever consulted.
func importPayloadImage(image, final string, m manifest) (string, error) {
	info, err := os.Lstat(image)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("offline payload image is not a regular file")
	}
	mount, err := os.MkdirTemp("", "idv-login-payload-")
	if err != nil {
		return "", err
	}
	device, err := attachDiskImage(image, mount)
	if err != nil {
		_ = os.Remove(mount)
		return "", err
	}
	// detachDiskImage also removes the private mountpoint, so a failure anywhere
	// below cannot strand a mounted payload on the host.
	defer detachDiskImage(device, mount)
	if err = requireSingleArtefact(mount, m); err != nil {
		return "", err
	}
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
	source, err := os.Open(filepath.Join(mount, m.AssetName))
	if err != nil {
		return "", err
	}
	out, err := os.OpenFile(partial, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		_ = source.Close()
		return "", err
	}
	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(out, hash), source)
	sourceErr := source.Close()
	closeErr := out.Close()
	if copyErr != nil || sourceErr != nil || closeErr != nil {
		_ = os.Remove(partial)
		if copyErr != nil {
			return "", copyErr
		}
		if sourceErr != nil {
			return "", sourceErr
		}
		return "", closeErr
	}
	if written != m.ByteSize || !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), m.SHA256) {
		_ = os.Remove(partial)
		return "", errors.New("offline payload artefact size or hash mismatch")
	}
	// regularArm64 re-checks size, digest and the arm64 Mach-O magic on the
	// published bytes, so an offline install cannot bypass the download checks.
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

// offlineManifest is the subset of OfflinePayloads/offlinePayloads.json the
// downloader relies on.  Packaging re-signs idv-login with this project's
// Developer ID (a secure timestamp makes the signature non-reproducible), so the
// bytes that must be installed are the ones recorded here, not the upstream
// release digest.  byteCount/sha256 still describe the upstream release: they
// prove the document was derived from the same lock the component manifest
// carries.
type offlineManifest struct {
	SchemaVersion int    `json:"schemaVersion"`
	Kind          string `json:"kind"`
	IDVLogin      struct {
		AssetName        string `json:"assetName"`
		Version          string `json:"version"`
		ByteCount        int64  `json:"byteCount"`
		SHA256           string `json:"sha256"`
		OfflineByteCount int64  `json:"offlineByteCount"`
		OfflineSHA256    string `json:"offlineSha256"`
	} `json:"idvLogin"`
}

var offlineHashRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

// readOfflineManifest derives the effective expectation for this build.  The
// document must still agree with the upstream lock on identity and on the
// upstream digest; only then is the re-signed offline expectation accepted.
func readOfflineManifest(path string, locked manifest) (int64, string, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, "", err
	}
	defer file.Close()
	var document offlineManifest
	if err = json.NewDecoder(io.LimitReader(file, 1<<20)).Decode(&document); err != nil {
		return 0, "", fmt.Errorf("invalid offline payload manifest: %w", err)
	}
	if document.SchemaVersion != 1 || document.Kind != "identityv-offline-payloads" {
		return 0, "", errors.New("unsupported offline payload manifest")
	}
	if document.IDVLogin.AssetName != locked.AssetName || document.IDVLogin.Version != locked.Version {
		return 0, "", errors.New("offline payload manifest does not describe the pinned component")
	}
	if document.IDVLogin.ByteCount != locked.ByteSize || !strings.EqualFold(document.IDVLogin.SHA256, locked.SHA256) {
		return 0, "", errors.New("offline payload manifest was not derived from the pinned upstream release")
	}
	if document.IDVLogin.OfflineByteCount < 1 || !offlineHashRE.MatchString(strings.ToLower(document.IDVLogin.OfflineSHA256)) {
		return 0, "", errors.New("offline payload manifest has no usable offline expectation")
	}
	return document.IDVLogin.OfflineByteCount, strings.ToLower(document.IDVLogin.OfflineSHA256), nil
}

// parseArgs keeps the original two-positional form byte-for-byte compatible and
// adds the paired offline disk-image form.  `--payload-image` and
// `--payload-manifest` must be supplied together: guessing the other half would
// silently verify against the wrong expectation, so a lone flag is a usage
// error rather than a fallback.  Both `--flag ABS` and `--flag=ABS` are accepted
// for either option, in any order, and the superseded gzip `--payload` form is
// rejected.
func parseArgs(args []string) (manifestPath, cache, payloadImage, payloadManifest string, err error) {
	if len(args) < 2 {
		return "", "", "", "", errors.New("missing arguments")
	}
	manifestPath, cache = args[0], args[1]
	rest := args[2:]
	for index := 0; index < len(rest); index++ {
		name, value, hasValue := strings.Cut(rest[index], "=")
		if name != "--payload-image" && name != "--payload-manifest" {
			return "", "", "", "", errors.New("unexpected arguments")
		}
		if !hasValue {
			index++
			if index >= len(rest) {
				return "", "", "", "", errors.New("missing option value")
			}
			value = rest[index]
		}
		if value == "" {
			return "", "", "", "", errors.New("empty option value")
		}
		if name == "--payload-image" {
			if payloadImage != "" {
				return "", "", "", "", errors.New("duplicate --payload-image")
			}
			payloadImage = value
			continue
		}
		if payloadManifest != "" {
			return "", "", "", "", errors.New("duplicate --payload-manifest")
		}
		payloadManifest = value
	}
	if (payloadImage == "") != (payloadManifest == "") {
		return "", "", "", "", errors.New("--payload-image and --payload-manifest must be supplied together")
	}
	return manifestPath, cache, payloadImage, payloadManifest, nil
}

func validatePinned(m manifest) error {
	if m.Component != "idv-login" || m.Version != "6.3.1" || m.AssetName != "idv-login-v6.3.1-beta-mac" || m.ByteSize != 197556448 || m.SHA256 != "c789cc56f320052419a4367fcb87971c2dd907e6af37ed8b6b1f8adb17a7bd45" || m.DownloadURL != "https://github.com/KKeygen/idv-login/releases/download/v6.3.1-beta/idv-login-v6.3.1-beta-mac" {
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
	manifestPath, cache, payloadImage, payloadManifest, err := parseArgs(os.Args[1:])
	if err != nil {
		fail("usage: %s manifest.json cache-directory [--payload-image ABS --payload-manifest ABS]", filepath.Base(os.Args[0]))
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
	p, e := acquire(m, cache, safeClient(), payloadImage, payloadManifest)
	if e != nil {
		fail("download component: %v", e)
	}
	fmt.Println(p)
}
