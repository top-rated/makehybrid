import "dotenv/config";
import type { Config } from "drizzle-kit";

export default {
  schema: ["./src/db/schema.ts", "./src/db/auth-schema.ts"],
  out: "./drizzle",
  dialect: "sqlite",
  dbCredentials: { url: process.env.DATABASE_PATH ?? "./dev.db" },
} satisfies Config;
