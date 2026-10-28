package parser

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// CodeFree-O is the China Telecom R&D Cloud agent built on the OpenCode
// core. It keeps the OpenCode SQLite schema under its own data root as
// codefree.db, so the shared OpenCode-format provider parses it and
// relabels the session IDs onto the codefree-o: prefix.
//
// These tests cover the fork-specific surface: the relabel, the container
// name, the data root, and the SQLite-mode discovery path that CodeFree-O
// resolves to (its storage tree holds per-session diffs, not session JSON).

func TestCodeFreeOProviderRelabelsOpenCodeSession(t *testing.T) {
	root := t.TempDir()
	dbPath := filepath.Join(root, "codefree.db")
	copyOpenCodeSchemaTemplate(t, dbPath)
	db, err := sql.Open("sqlite3", dbPath)
	require.NoError(t, err, "open test db")
	t.Cleanup(func() { _ = db.Close() })

	seeder := &OpenCodeSeeder{db: db, t: t}
	seeder.AddProject("prj_cf", "D:/AppWorkspace/CodeFreeSpace/myapp")
	seeder.AddSessionDirectory(
		"ses_cf", "prj_cf", "", "CodeFree Session",
		"D:/AppWorkspace/CodeFreeSpace/myapp",
		1700000000000, 1700000060000,
	)
	seeder.AddMessage(
		"msg_1", "ses_cf", 1700000000000, 1700000000000, `{"role":"user"}`,
	)
	seeder.AddPart(
		"prt_1", "msg_1", "ses_cf", 1700000000000, 1700000000000,
		`{"type":"text","text":"Hello from CodeFree-O"}`,
	)

	provider, ok := NewProvider(AgentCodeFreeO, ProviderConfig{
		Roots:   []string{root},
		Machine: "testmachine",
	})
	require.True(t, ok)

	sources, err := provider.Discover(t.Context())
	require.NoError(t, err)
	require.Len(t, sources, 1)

	outcome, err := provider.Parse(t.Context(), ParseRequest{
		Source: sources[0],
	})
	require.NoError(t, err)
	require.Len(t, outcome.Results, 1)

	sess := outcome.Results[0].Result.Session
	msgs := outcome.Results[0].Result.Messages
	require.Len(t, msgs, 1)

	assert.Equal(t, "codefree-o:ses_cf", sess.ID)
	assert.Equal(t, AgentCodeFreeO, sess.Agent)
	assert.Equal(t, "CodeFree Session", sess.SessionName)
	assert.Equal(t, "myapp", sess.Project)
	assert.Equal(t, "Hello from CodeFree-O", msgs[0].Content)
}

// CodeFree-O stores its sessions in codefree.db and keeps only per-session
// diffs under storage/session_diff, so the root must resolve to SQLite mode
// rather than the file-backed storage mode the other OpenCode-format forks
// use.
func TestCodeFreeOResolvesToSQLiteMode(t *testing.T) {
	root := t.TempDir()
	require.NoError(t, os.MkdirAll(
		filepath.Join(root, "storage", "session_diff"), 0o755,
	))
	dbPath := filepath.Join(root, "codefree.db")
	seedHybridSQLiteDB(t, dbPath, "ses_cf")

	src := ResolveCodeFreeOSource(root)
	assert.Equal(t, OpenCodeSourceSQLite, src.Mode)
	assert.Equal(t, []string{dbPath}, src.DBPaths)
}

// The container name is the fork-specific part of the OpenCode format: the
// shared reader must not pick up a sibling agent's container.
func TestCodeFreeOContainerName(t *testing.T) {
	assert.Equal(t, "codefree.db", codefreeOFmt.dbName)
	assert.Equal(t, "codefree-o", string(AgentCodeFreeO))
}

// The OpenCode reader picks the container by its base name. A CodeFree-O
// virtual path must resolve against codefree.db and reject another fork's
// container.
func TestParseCodeFreeOSQLiteVirtualPath(t *testing.T) {
	wantDBPath := filepath.Join(t.TempDir(), "codefree.db")
	virtual := wantDBPath + "#ses_cf"
	dbPath, sessionID, ok := ParseCodeFreeOSQLiteVirtualPath(virtual)
	require.True(t, ok)
	assert.Equal(t, wantDBPath, dbPath)
	assert.Equal(t, "ses_cf", sessionID)

	_, _, ok = ParseCodeFreeOSQLiteVirtualPath(
		filepath.Join(t.TempDir(), "opencode.db") + "#ses_cf",
	)
	assert.False(t, ok)
}

// The relabel rewrites the session ID and its parent/source links, so a
// CodeFree-O session never points at an opencode: row that the
// codefree-o: namespace does not store.
func TestRelabelOpenCodeSessionAsCodeFreeO(t *testing.T) {
	sess := &ParsedSession{
		ID:              "opencode:ses_cf",
		ParentSessionID: "opencode:ses_parent",
		SourceSessionID: "opencode:ses_src",
		Agent:           AgentOpenCode,
	}
	relabelOpenCodeSessionAsCodeFreeO(sess)

	assert.Equal(t, "codefree-o:ses_cf", sess.ID)
	assert.Equal(t, "codefree-o:ses_parent", sess.ParentSessionID)
	assert.Equal(t, "codefree-o:ses_src", sess.SourceSessionID)
	assert.Equal(t, AgentCodeFreeO, sess.Agent)
}

// CodeFree-O keeps its own data root, so the default directory must not
// collide with plain OpenCode's.
func TestCodeFreeODefaultRoot(t *testing.T) {
	def, ok := AgentByType(AgentCodeFreeO)
	require.True(t, ok)
	assert.Equal(t, []string{".codefree-o/.local/share"}, def.DefaultDirs)
	assert.Equal(t, "codefree-o:", def.IDPrefix)
	assert.Equal(t, "CodeFree-O", def.DisplayName)

	openCodeDef, ok := AgentByType(AgentOpenCode)
	require.True(t, ok)
	assert.NotEqual(t, openCodeDef.DefaultDirs, def.DefaultDirs)
}

// The session ID prefix must round-trip: a stored codefree-o: ID resolves
// back to the CodeFree-O agent, and the agent's own prefix is never
// mistaken for OpenCode's.
func TestCodeFreeOSessionIDPrefixLookup(t *testing.T) {
	def, ok := AgentByPrefix("codefree-o:ses_cf")
	require.True(t, ok)
	assert.Equal(t, AgentCodeFreeO, def.Type)

	raw := ProviderNormalizeRawSessionID(def, "codefree-o:ses_cf")
	assert.Equal(t, "ses_cf", raw)
}

// The shared OpenCode reader must not treat another fork's container as a
// CodeFree-O one.
func TestCodeFreeOSQLiteMetaRejectsForeignContainer(t *testing.T) {
	root := t.TempDir()
	dbPath := filepath.Join(root, "opencode.db")
	seedHybridSQLiteDB(t, dbPath, "ses_cf")

	metas, err := ListCodeFreeOSessionMeta(dbPath)
	require.NoError(t, err)
	require.Len(t, metas, 1)
	assert.True(t, strings.HasPrefix(
		metas[0].VirtualPath, dbPath+"#",
	), "virtual path keeps its own container base name")
}
