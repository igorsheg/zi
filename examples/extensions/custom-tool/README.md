# Repository status extension

Copy `index.ts` to `.zi/extensions/repository-status/index.ts` in a repository, start Zi there, and choose **Trust and remember**. The model can then call `repository_status` with an optional repository-relative path.

The extension imports only `@with-zi/extension-api`. Zi loads the TypeScript source directly; no extension build is required.
