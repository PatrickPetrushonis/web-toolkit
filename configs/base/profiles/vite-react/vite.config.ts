// This file is NOT auto-applied by init.sh or update.sh; both scripts
// only print a warning pointing here for manual review. Copy the
// structural pieces below into a new project's vite.config.ts by hand,
// then layer that project's own instance-specific plugins (image
// processing, dev-server proxies, custom ports, asset-directory paths)
// on top. Don't extend this template file itself with instance-specific
// content - it stops being reusable the moment it is.

import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { copyFileSync, mkdirSync } from 'fs';
import { resolve } from 'path';

// Update this list to match every static <Route path="..."> in
// App.tsx, excluding the "*" catch-all AND any dynamic segment (e.g.
// "/item/:id" cannot be pre-rendered as a fixed directory). This can be
// checked automatically by diffing this array against App.tsx's static
// <Route> paths (see update.sh's route parity check); it is not
// necessarily a purely manual sync, even though nothing enforces it in
// this template as written.
const routes: string[] = [];

export default defineConfig({
  // '/' for a custom domain or user page (username.github.io).
  // '/repo-name/' for a project page with no custom domain.
  base: '/',
  plugins: [
    react(),
    {
      name: 'gh-pages-spa-routes',
      closeBundle() {
        for (const route of routes) {
          mkdirSync(resolve('dist', route), { recursive: true });
          copyFileSync(resolve('dist/index.html'), resolve('dist', route, 'index.html'));
        }
        copyFileSync(resolve('dist/index.html'), resolve('dist/404.html'));
      },
    },
  ],
});
