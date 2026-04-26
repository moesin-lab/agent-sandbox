import express from "express";

const app = express();

app.get("/health", (_req, res) => {
  res.json({
    service: "web",
    ok: true,
    tools: ["search_web_stub", "fetch_url_stub"]
  });
});

app.listen(3102, () => {
  console.log("web mcp stub listening on 3102");
});
