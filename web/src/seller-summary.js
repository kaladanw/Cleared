// Seller view summary: count + verdict mix for the rows currently shown.

export function summarizeSeller(rows) {
  const mix = { buy: 0, negotiate: 0, skip: 0, other: 0 };
  for (const row of rows || []) {
    const rec = row.verdict || row.report_json?.verdict?.recommendation || "";
    if (rec in mix && rec !== "other") mix[rec] += 1;
    else mix.other += 1;
  }
  return { count: (rows || []).length, mix };
}

export function sellerSummaryText(username, summary) {
  const parts = [`${summary.count} check${summary.count === 1 ? "" : "s"}`];
  const mixParts = [];
  if (summary.mix.buy) mixParts.push(`${summary.mix.buy} buy`);
  if (summary.mix.negotiate) mixParts.push(`${summary.mix.negotiate} negotiate`);
  if (summary.mix.skip) mixParts.push(`${summary.mix.skip} skip`);
  if (summary.mix.other) mixParts.push(`${summary.mix.other} other`);
  if (mixParts.length) parts.push(mixParts.join(" · "));
  return `@${username} — ${parts.join(" — ")}`;
}
