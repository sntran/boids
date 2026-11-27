// The entry of the site on Cloudflare Workers: app.com (npm run build)
// with the engine of the npm package beam.com.
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';

// Stateful: the Durable Object Beam (the binding BEAM of wrangler.jsonc)
// runs one VM for all the visitors. The flocks of the pages are processes
// of that VM, and the VM runs while a visitor has a page open.
export { Beam } from 'beam.com';

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
