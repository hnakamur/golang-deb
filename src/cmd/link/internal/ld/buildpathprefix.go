// Copyright 2010 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package ld

import (
	"log"
	"os"
	"strings"
	"sync"
)

func decode(s string) string {
	s = strings.Replace(s, "%.", ":", -1)
	s = strings.Replace(s, "%+", "=", -1)
	s = strings.Replace(s, "%#", "%", -1)
	return s
}

type prefixMapEntry struct {
	target string
	source string
}

var (
	buildPathPrefixMap     []prefixMapEntry
	buildPathPrefixMapOnce sync.Once
)

// See https://reproducible-builds.org/specs/build-path-prefix-map/
func applyBuildPathPrefixMap(dir string) string {
	// Parse the BUILD_PATH_PREFIX_MAP only once; this function gets called for
	// every compiled file.
	buildPathPrefixMapOnce.Do(func() {
		for _, item := range strings.Split(os.Getenv("BUILD_PATH_PREFIX_MAP"), ":") {
			if strings.TrimSpace(item) == "" {
				continue
			}
			parts := strings.Split(item, "=")
			if got, want := len(parts), 2; got != want {
				log.Fatalf("parsing BUILD_PATH_PREFIX_MAP: incorrect number of = separators in item %q: got %d, want %d", item, got-1, want-1)
			}
			buildPathPrefixMap = append(buildPathPrefixMap, prefixMapEntry{
				target: decode(parts[0]),
				source: decode(parts[1]),
			})
		}
	})
	for _, e := range buildPathPrefixMap {
		if strings.HasPrefix(dir, e.source) {
			return e.target + strings.TrimPrefix(dir, e.source)
		}
	}
	return dir
}
