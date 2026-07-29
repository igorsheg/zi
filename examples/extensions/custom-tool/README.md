# Repository status extension

Copy `index.ts` to `.zi/extensions/repository-status/index.ts` in a repository, start Zi there, and choose **Trust and remember**. The model can then call `repository_status` with an optional repository-relative path.

The extension declares a structured output schema. Direct calls receive its JSON rendering, while Code Mode receives the validated object directly. Zi loads the TypeScript source without an extension build.
