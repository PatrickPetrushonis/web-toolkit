import { defineConfig } from 'astro/config';

// Hand-authored per project, not auto-applied - see manifest.json's
// hand_authored list, same status as vite.config.ts in the vite-react
// profile. `site` needs this project's actual custom domain or GitHub
// Pages subpath. If any interactive islands are needed (a theme
// toggle, reading progress), add that framework's integration here
// (e.g. @astrojs/react, @astrojs/svelte) - which framework a project's
// islands use is project-specific, not part of this baseline.
export default defineConfig({
  site: 'https://example.com',
  output: 'static',
});
