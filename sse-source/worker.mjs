// Frame/cadence protocol adapted from lop-spec/stream-quality (MIT).
export const profile = 'fc-sse-v1-256b-50ms-8s';
export const samples = 161;
const encoder = new TextEncoder();
let active = 0;
export function frame(seq, sentMs) {
  const data = { seq, sentMs: Math.round(sentMs * 10) / 10, scheduledMs: seq * 50, pad: '' };
  const render = () => `event: sample\ndata: ${JSON.stringify(data)}\n\n`;
  data.pad = 'x'.repeat(256 - encoder.encode(render()).length);
  return render();
}
export const endFrame = () => `event: end\ndata: ${JSON.stringify({ profile, samples })}\n\n`;
export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return Response.json({ profile, samples, durationMs: 8000, active });
    if (request.method !== 'GET' || url.pathname !== '/api/stream') return new Response('Not found', { status: 404 });
    if (active >= 1024) return new Response('Source busy; not a node failure', { status: 429 });
    active++;
    let finished = false, timer;
    const finish = () => { if (!finished) { finished = true; active--; clearTimeout(timer); } };
    const stream = new ReadableStream({
      start(controller) {
        const start = performance.now();
        let seq = 0;
        const tick = () => {
          if (finished) return;
          try {
            const elapsed = performance.now() - start;
            if (elapsed > 10500) { controller.error(Error('source deadline')); finish(); return; }
            controller.enqueue(encoder.encode(frame(seq, elapsed)));
            seq++;
            if (seq === samples) { controller.enqueue(encoder.encode(endFrame())); controller.close(); finish(); return; }
            timer = setTimeout(tick, Math.max(0, seq * 50 - (performance.now() - start)));
          } catch { finish(); }
        };
        tick();
      },
      cancel() { finish(); },
    });
    return new Response(stream, { headers: {
      'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store, no-transform',
      'x-stream-quality-profile': profile, 'x-stream-quality-location': request.cf?.colo || 'local',
      'x-accel-buffering': 'no',
    } });
  },
};
