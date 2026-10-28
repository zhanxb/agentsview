package parser

import (
	"context"
	"strings"
)

// CodeFree-O is the China Telecom R&D Cloud coding agent, built on the
// OpenCode core. It stores its sessions in codefree.db under
// ~/.codefree-o/.local/share, using the same SQLite schema OpenCode does, and
// keeps per-session diffs in a storage/session_diff tree. Discovery and
// parsing run through the shared OpenCode-format provider
// (openCodeProviderSpecForAgent); the helpers below adapt the shared SQLite
// metadata reader, source mtime, and session relabeling to CodeFree-O.
func ListCodeFreeOSessionMeta(dbPath string) ([]OpenCodeSessionMeta, error) {
	metas, err := ListOpenCodeSessionMeta(dbPath)
	if err != nil {
		return nil, err
	}
	for i := range metas {
		metas[i].VirtualPath = CodeFreeOSQLiteVirtualPath(
			dbPath, metas[i].SessionID,
		)
	}
	return metas, nil
}

func CodeFreeOSourceMtime(ctx context.Context, sourcePath string) (int64, error) {
	if sourcePath == "" {
		return 0, nil
	}
	if dbPath, sessionID, ok := ParseCodeFreeOSQLiteVirtualPath(sourcePath); ok {
		return openCodeSQLiteSessionMtime(ctx, dbPath, sessionID)
	}
	return openCodeStorageSessionMtime(sourcePath)
}

func relabelOpenCodeSessionAsCodeFreeO(sess *ParsedSession) {
	sess.ID = strings.Replace(sess.ID, "opencode:", "codefree-o:", 1)
	if sess.ParentSessionID != "" {
		sess.ParentSessionID = strings.Replace(
			sess.ParentSessionID, "opencode:", "codefree-o:", 1,
		)
	}
	if sess.SourceSessionID != "" {
		sess.SourceSessionID = strings.Replace(
			sess.SourceSessionID, "opencode:", "codefree-o:", 1,
		)
	}
	sess.Agent = AgentCodeFreeO
}
