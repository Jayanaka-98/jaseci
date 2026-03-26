"""Content Summarizer - byLLM+OSP reimplementation of the summarize skill."""

import from typing { Optional }

# --- Structured types for extraction ---
enum ContentType { URL, YOUTUBE, LOCAL_FILE }

obj SummaryResult {
    has title: str,
        content_type: str,
        summary: str,
        key_points: list[str];
}

# --- Tool functions (things the LLM can call) ---
"""Fetch text content from a web URL."""
def fetch_url(url: str) -> str {
    import from urllib.request { urlopen }
    response = urlopen(url);
    html = response.read().decode("utf-8");
    return html;
}

"""Read content from a local file path."""
def read_file(file_path: str) -> str {
    f = open(file_path, "r");
    content = f.read();
    f.close();
    return content;
}

"""Extract transcript text from a YouTube video URL."""
def fetch_youtube_transcript(url: str) -> str {
    return f"[Transcript placeholder for {url}]";
}

# --- byLLM functions (Generate + Extract) ---
"""Summarize the given text content into a structured result with title, summary, and key points."""
def summarize_text(content: str, desired_length: str) -> SummaryResult by llm();

sem summarize_text = """Summarize the given content. Return:
- title: a short descriptive title
- content_type: the type of content (url, youtube, or local_file)
- summary: a summary matching the desired_length (short=1-2 sentences, medium=paragraph, long=multiple paragraphs)
- key_points: 3-5 bullet point takeaways""";

# --- OSP: Graph nodes for content routing ---
node URLHandler {
    has description: str = "Handles regular web URLs - fetches HTML and summarizes articles or web pages";
}

node YouTubeHandler {
    has description: str = "Handles YouTube video URLs (youtube.com, youtu.be) - extracts transcript and summarizes";
}

node FileHandler {
    has description: str = "Handles local file paths - reads files from disk and summarizes their content";
}

# --- OSP: Walker as the agent ---
walker Summarizer {
    has source: str,
        length: str = "medium",
        result: SummaryResult | None = None;

    # Route: LLM reads node descriptions and picks the right handler
    can route with Root entry {
        visit [-->] by llm(incl_info={"User input source": self.source});
    }

    # Process URL content
    can handle_url with URLHandler entry {
        content = fetch_url(self.source);
        self.result = summarize_text(content, self.length);
        self.result.content_type = "url";
    }

    # Process YouTube content
    can handle_youtube with YouTubeHandler entry {
        transcript = fetch_youtube_transcript(self.source);
        self.result = summarize_text(transcript, self.length);
        self.result.content_type = "youtube";
    }

    # Process local file content
    can handle_file with FileHandler entry {
        content = read_file(self.source);
        self.result = summarize_text(content, self.length);
        self.result.content_type = "local_file";
    }
}

# --- Entry point ---

# Build the routing graph: root connects to all handlers
with entry {
    root ++> URLHandler();
    root ++> YouTubeHandler();
    root ++> FileHandler();
}

# Spawn the summarizer - LLM routes to the correct handler
glob walker_result = root spawn Summarizer(
         source="https://example.com/article", length="medium"
     );

# Display results
with entry {
    if walker_result.result {
        r = walker_result.result;
        print(f"Title: {r.title}");
        print(f"Type:  {r.content_type}");
        print(f"\n{r.summary}");
        print("\nKey Points:");
        for point in r.key_points {
            print(f"  - {point}");
        }
    }
}
