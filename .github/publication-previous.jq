def valid_sha:
  type == "string" and test("^[0-9a-f]{64}$");

if .schema != "velnor.publication-record/v1" then
  error("unsupported publication record schema")
elif .tag == $prior then
  if (.source_record_sha256 | valid_sha) then
    {tag, source_record_sha256}
  else
    error("prior publication record checksum is invalid")
  end
elif .tag == $candidate then
  if .source_record_sha256 != $candidate_sha then
    error("published candidate differs from immutable source release")
  elif .previous.tag != $prior then
    error("published rollback tag differs from signed package pair")
  elif (.previous.source_record_sha256 | valid_sha) then
    .previous | {tag, source_record_sha256}
  else
    error("published rollback checksum is invalid")
  end
else
  error("publication record identifies neither candidate nor rollback")
end
