import fs from "node:fs";

export function loadProfile(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}
