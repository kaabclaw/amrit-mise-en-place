# Amrit Mise en Place — SOPs & Checklists

Single-page app for SOPs and checklists at Amrit Ocean Resort.

## Current Structure
- All SOPs and checklists render as an accordion list on a single page
- Clicking an item expands it inline within the list
- Auth-gated via Supabase on the live site

## Redesign Brief
The goal is to move away from the accordion/inline-expand pattern to:
1. A clean card grid index (filterable by outlet/department/type)
2. Each SOP/checklist opens on its own dedicated page with a unique URL
3. A public preview route with no auth required (read-only, banner identifying it as preview)

## Files
- `index.html` — the full current page (auth removed for review purposes)
- `assets/` — logo and supporting assets
