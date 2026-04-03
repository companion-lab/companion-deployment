Deno.serve(() =>
  Response.json({
    ok: true,
    service: "supabase-edge-functions",
    message: "Edge runtime placeholder is running",
  }),
);
