defmodule AlplusWeb.ReferrerFavicon do
  @moduledoc "Maps common referrer hosts to the self-hosted favicon sprite."

  @symbols %{
    "google.com" => "google",
    "bing.com" => "bing",
    "yahoo.com" => "yahoo",
    "duckduckgo.com" => "duckduckgo",
    "github.com" => "github",
    "gitlab.com" => "gitlab",
    "bitbucket.org" => "bitbucket",
    "linkedin.com" => "linkedin",
    "facebook.com" => "facebook",
    "instagram.com" => "instagram",
    "x.com" => "x",
    "twitter.com" => "x",
    "reddit.com" => "reddit",
    "youtube.com" => "youtube",
    "t.co" => "x",
    "producthunt.com" => "producthunt",
    "news.ycombinator.com" => "hackernews",
    "stackoverflow.com" => "stackoverflow",
    "medium.com" => "medium",
    "dev.to" => "devto",
    "hashnode.com" => "hashnode",
    "npmjs.com" => "npm",
    "slack.com" => "slack",
    "discord.com" => "discord",
    "notion.so" => "notion",
    "substack.com" => "substack",
    "pinterest.com" => "pinterest",
    "tiktok.com" => "tiktok",
    "threads.net" => "threads",
    "mastodon.social" => "mastodon",
    "quora.com" => "quora",
    "wikipedia.org" => "wikipedia",
    "perplexity.ai" => "perplexity",
    "chatgpt.com" => "chatgpt",
    "claude.ai" => "claude",
    "gemini.google.com" => "gemini",
    "yandex.com" => "yandex",
    "baidu.com" => "baidu",
    "ecosia.org" => "ecosia",
    "brave.com" => "brave"
  }

  def symbol(host) when is_binary(host), do: Map.get(@symbols, String.downcase(host), "generic")
  def symbol(_host), do: "generic"

  def sprite_href(host), do: "/images/referrer-favicons.svg##{symbol(host)}"
end
