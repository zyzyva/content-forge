# School of Hard Knocks — Reference Material

Source: bonus content from the School of Content course (Hard Knocks team), shared via Google Drive folder `1v5Hx18rU8gpnPSg8eFmDGvD4an4iJ1AG` by `athan@shophardknocks.com`.

This folder is **seed data** — it represents the kind of external reference material that ContentForge's ingestion pipeline (see `REFERENCE_INGESTION_PLAN.md` at repo root) is being built to handle. Once that feature ships, the same files should be re-ingested through the pipeline rather than read from disk.

## What's here

| File | Type | Status |
| --- | --- | --- |
| `1000_viral_hooks.md` | Hook template library (≈1,000 fill-in-the-blank templates with example post URLs across categories: Educational, Comparison, Myth Busting, Storytelling, Random, Authority, Day-in-the-Life) | Complete (1,415 lines, ≈150 KB) |
| `viral_script_machine.md` | 4-step workflow for the Hard Knocks "Viral Script Lab" custom GPT | Tail truncated by Drive MCP — re-fetch via the ingestion pipeline once it lands |
| `prompt_library.md` | 6 reusable prompts: My Voice (Voice DNA), Viral Hooks, Viral Script, Find Example Pages, Content Calendar, 100 Viral Hooks | Tail truncated by Drive MCP — substance complete |

## What's missing (still in Drive only)

13 video files totalling ≈21 GB, none transcribed yet:

| Title | Size |
| --- | --- |
| Hooks Masterclass | 2.45 GB |
| How To Master Editing To Get Millions Of Views | 1.01 GB |
| How Top Creators Automate Long-Form YouTube | 2.59 GB |
| Manychat Masterclass | 380 MB |
| Monetize Your Brand Workshop | 3.25 GB |
| Our Journey to a Billion Views: Lesson's Learned | 3.93 GB |
| Personal Brand Workshop | 1.98 GB |
| Social Media Algorithm & Virality Masterclass | 2.39 GB |
| The FOMO Trick Driving Viral Shorts | 2.22 GB |
| The Viral Intro Formula | 334 MB |

The video file IDs are recorded in the ingestion plan so the transcription job can fetch them once that slice ships.

## Why this is relevant to ContentForge

The product spec already calls for a **voice profile** (per product) and **competitor intel** (per product, scraped). Neither concept covers cross-product, evergreen reference material like proven hook templates and reusable copywriting prompts. The ingestion plan adds a third concept — **reference library** — that the content brief and OC generation can pull from regardless of product.
