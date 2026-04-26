import express from "express";

const app = express();

app.get("/health", (_req, res) => {
  res.json({ service: "github", ok: true, tools: ["create_pr_stub"] });
});

app.listen(3101, () => {
  console.log("github mcp stub listening on 3101");
});
