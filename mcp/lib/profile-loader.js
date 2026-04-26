import fs from "node:fs";

export function loadProfile(path) {
  let parsed;

  try {
    parsed = JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Failed to load MCP profile from ${path}: ${error.message}`);
  }

  if (typeof parsed !== "object" || parsed === null) {
    throw new Error(`Invalid MCP profile at ${path}: expected object`);
  }

  if (typeof parsed.name !== "string" || parsed.name.length === 0) {
    throw new Error(`Invalid MCP profile at ${path}: missing name`);
  }

  if (!Array.isArray(parsed.services)) {
    throw new Error(`Invalid MCP profile at ${path}: services must be an array`);
  }

  return parsed;
}
