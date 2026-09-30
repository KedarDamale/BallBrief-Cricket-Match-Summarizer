 .PHONY: run

run:
	uv run uvicorn ballbrief_cricket_match_summarizer.main:app --app-dir src --reload
