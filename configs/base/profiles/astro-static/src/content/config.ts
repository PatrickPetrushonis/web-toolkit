// Hand-authored per project, not auto-applied - see manifest.json's
// hand_authored list. Defines this project's own content collection
// schema; there is no baseline schema that fits every astro-static
// project (a serial-fiction site's chapter frontmatter is a different
// shape than a blog's post frontmatter, for example).
import { defineCollection, z } from 'astro:content';

const exampleCollection = defineCollection({
  schema: z.object({
    title: z.string(),
  }),
});

export const collections = {
  example: exampleCollection,
};
