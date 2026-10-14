defmodule AlplusWeb.BlogHTML do
  use AlplusWeb, :html

  import AlplusWeb.MarketingComponents

  embed_templates "blog_html/*"

  def body_classes do
    "mt-10 space-y-5 break-words text-body-long text-text-secondary " <>
      "[&_h2]:scroll-mt-6 [&_h2]:pt-5 [&_h2]:text-heading-02 [&_h2]:font-semibold [&_h2]:text-text-primary " <>
      "[&_h3]:pt-3 [&_h3]:text-heading-03 [&_h3]:font-semibold [&_h3]:text-text-primary " <>
      "[&_a]:text-interactive-strong [&_a]:underline [&_a]:underline-offset-4 " <>
      "[&_ol]:list-decimal [&_ol]:pl-6 [&_ul]:list-disc [&_ul]:pl-6 [&_li]:my-2 " <>
      "[&_code]:rounded-control-sm [&_code]:bg-surface-sunken [&_code]:px-1.5 [&_code]:font-mono [&_code]:text-data " <>
      "[&_pre]:overflow-x-auto [&_pre]:rounded-frame [&_pre]:bg-surface-inverse [&_pre]:p-4 [&_pre]:text-surface-page " <>
      "[&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_table]:block [&_table]:overflow-x-auto " <>
      "[&_th]:text-left [&_th]:text-text-primary [&_th]:font-semibold [&_th]:p-3 " <>
      "[&_td]:p-3 [&_tr]:border-b [&_tr]:border-border-default"
  end
end
