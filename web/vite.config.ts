import { defineConfig } from "vite";
import solid from "@solidjs/vite-plugin";

export default defineConfig({
    base: "/admin/",
    publicDir: "../assets",
    plugins: [solid()],
    server: {
        proxy: {
            "/admin/api": {
                target: process.env.ADMIN_API_TARGET ?? "http://127.0.0.1:8080",
                changeOrigin: false,
            },
        },
    },
    build: {
        rollupOptions: {
            output: {
                entryFileNames: "assets/admin.js",
                chunkFileNames: "assets/[name].js",
                assetFileNames: "assets/admin[extname]",
            },
        },
    },
});
