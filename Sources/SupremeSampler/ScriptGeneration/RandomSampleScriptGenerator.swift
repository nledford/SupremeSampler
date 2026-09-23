import Foundation

/// Generates a standalone Photo Supreme `.psc` script: a filtered,
/// randomized sample of catalog items. Structurally identical to
/// `RandomCatalogSample.psc` (the hand-written script this whole app
/// exists to generalize -- see AGENTS.md for the interpreter quirks it
/// works around), with the sample size and an optional WHERE-clause
/// predicate spliced into its two SQL queries.
///
/// A pure function of its inputs: no file I/O, no catalog access. It
/// just produces text, for a UI to show in a preview pane before the
/// user decides whether to save it. Saving to disk and validating a
/// filter's match count first (via `PhotoSupremeCatalog`) are the
/// caller's job, not this type's -- same "keep I/O out of the thing
/// that's easy to unit test" reasoning as `PascalStringLiteral` and
/// `SQLPredicateText`.
///
/// The boilerplate lines below (everything except SAMPLE_SIZE and the
/// two CommandText assignments) are transcribed directly from the real,
/// committed, verified-compiling-and-running script rather than
/// re-derived -- deliberately, to inherit its already-paid-for
/// correctness (see `RandomSampleScriptGeneratorTests` for the
/// regression test against transcription drift) instead of re-risking
/// every interpreter quirk documented in AGENTS.md a second time.
enum RandomSampleScriptGenerator {
    static func generate(
        sampleSize: Int,
        filter: SampleFilter = SampleFilter(),
        generatedAt: Date = Date()
    ) -> String {
        let predicate = SQLPredicateText.render(filter)

        var lines: [String] = headerLines(filter: filter, generatedAt: generatedAt)
        lines += [
            "",
            "const",
            "  SAMPLE_SIZE = \(sampleSize);",
            "",
            "// Extra margin above the expected hit count when oversampling random",
            "// rowids. Benchmarked safe at 2.4x oversample against the real catalog.",
            "const",
            "  ROWID_OVERSAMPLE_MARGIN = 1.15;",
            "",
            "// Safety cap on retry passes, in case a shortfall never closes.",
            "const",
            "  ROWID_MAX_SAMPLE_ATTEMPTS = 8;",
            "",
            "// Hard ceiling on random rowids drawn per pass, in case catalog",
            "// density ever drops low enough to make a batch huge.",
            "const",
            "  ROWID_MAX_BATCH_SIZE = 100000;",
            "",
            "function RandomItemGUIDs(ACount: Integer): TStringList;",
            "var",
            "  AExtentSet: TDBXOMClientDataSet;",
            "  ASampleSet: TDBXOMClientDataSet;",
            "  ACandidates: TStringList;",
            "  ATotalRows, AMaxRowID: Integer;",
            "  ADensity: Double;",
            "  ABatchSize, AAttempt, AShortfall, I: Integer;",
            "begin",
            "  Randomize;",
            "  result := TStringList.Create;",
            "  result.Sorted := True;",
            "  result.Duplicates := dupIgnore;",
            "",
            "  AExtentSet := PublicCatalog.NewDataSet;",
            "  try",
        ]
        lines += extentCommandTextLines(predicate: predicate)
        lines += [
            "    AExtentSet.OpenSet;",
            "    ATotalRows := AExtentSet.FieldValue('RowCount');",
            "    AMaxRowID := AExtentSet.FieldValue('MaxRowID');",
            "    AExtentSet.CloseSet;",
            "  finally",
            "    PublicCatalog.FreeDataSet(AExtentSet);",
            "  end;",
            "",
            "  if (ATotalRows > 0) and (AMaxRowID > 0) then",
            "  begin",
            "    if ACount > ATotalRows then",
            "      ACount := ATotalRows;",
            "",
            "    ADensity := ATotalRows / AMaxRowID;",
            "",
            "    AAttempt := 0;",
            "    while (result.Count < ACount) and (AAttempt < ROWID_MAX_SAMPLE_ATTEMPTS) do",
            "    begin",
            "      Inc(AAttempt);",
            "      AShortfall := ACount - result.Count;",
            "      ABatchSize := Trunc(AShortfall / ADensity * ROWID_OVERSAMPLE_MARGIN) + 1;",
            "      if ABatchSize > ROWID_MAX_BATCH_SIZE then",
            "        ABatchSize := ROWID_MAX_BATCH_SIZE;",
            "",
            "      ACandidates := TStringList.Create;",
            "      try",
            "        for I := 1 to ABatchSize do",
            "          ACandidates.Add(IntToStr(Trunc(Random * AMaxRowID) + 1));",
            "",
            "        ASampleSet := PublicCatalog.NewDataSet;",
            "        try",
        ]
        lines += sampleCommandTextLines(predicate: predicate)
        lines += [
            "          ASampleSet.OpenSet;",
            "          while (not ASampleSet.EndOfSet) and (result.Count < ACount) do",
            "          begin",
            "            result.Add(ASampleSet.FieldValue('GUID'));",
            "            ASampleSet.NextInSet;",
            "          end;",
            "          ASampleSet.CloseSet;",
            "        finally",
            "          PublicCatalog.FreeDataSet(ASampleSet);",
            "        end;",
            "      finally",
            "        ACandidates.Free;",
            "      end;",
            "    end;",
            "  end;",
            "end;",
            "",
            "",
            "// Materializes the random GUIDs into full catalog items (with datasets).",
            "function BuildRandomItems: TCatalogItems;",
            "var",
            "  AGUIDs: TStringList;",
            "  AClassGUID: String;",
            "begin",
            "  result := TCatalogItems.Create(TCatalogItem, '');",
            "",
            "  AGUIDs := RandomItemGUIDs(SAMPLE_SIZE);",
            "  try",
            "    AClassGUID := PublicCatalog.StoreItemGUIDsToTempList(AGUIDs, False);",
            "    try",
            "      PublicCatalog.EnumItemsFromTempListGUID(AClassGUID, result);",
            "    finally",
            "      PublicCatalog.RemoveItemsFromTempListForClassGUID(AClassGUID);",
            "    end;",
            "  finally",
            "    AGUIDs.Free;",
            "  end;",
            "end;",
            "",
            "",
            "procedure OpenNewTabForDataset(ADatasets: TDBXOMDataSets);",
            "var",
            "  AData: TidElement;",
            "  AColl: Variant;",
            "begin",
            "  AData := TidElement.Create(nil);",
            "  try",
            "    PublicBroadCast(nil, 'OpenNewTab', nil);",
            "    PublicBroadCastRequest(nil, 'ActiveCollection', AData);",
            "    AColl := AData.Data;",
            "    AColl.Clear;",
            "    AColl.Items._DataSets := ADatasets;",
            "    PublicBroadCast(nil, 'RefreshActiveCollection', nil);",
            "  finally",
            "    AData.Free;",
            "  end;",
            "end;",
            "",
            "",
            "procedure OpenRandomSample;",
            "var",
            "  AItems: TCatalogItems;",
            "  ADatasets: TDBXOMDataSets;",
            "begin",
            "  AItems := BuildRandomItems;",
            "  try",
            "    ADatasets := AItems.DataSets;",
            "    AItems._DataSets := TDBXOMDataSets.Create(TDBXOMDataSet, '');",
            "  finally",
            "    AItems.Free;",
            "  end;",
            "",
            "  OpenNewTabForDataset(ADatasets);",
            "end;",
            "",
            "",
            "begin",
            "  OpenRandomSample;",
            "end;",
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Header

    private static func headerLines(filter: SampleFilter, generatedAt: Date) -> [String] {
        var lines = [
            "{",
            "  Random Catalog Sample",
            "  =====================",
            "",
            "  Returns a fresh random sample of catalog items in a new Photo Supreme tab.",
        ]

        let filterLines = filterSummaryLines(filter)
        if !filterLines.isEmpty {
            lines.append("")
            lines += filterLines
        }

        lines += [
            "",
            "  Generated by SupremeSampler on \(ISO8601DateFormatter().string(from: generatedAt)).",
            "}",
        ]
        return lines
    }

    private static func filterSummaryLines(_ filter: SampleFilter) -> [String] {
        // Purely descriptive -- never parsed back out. The actual filter
        // logic lives in the WHERE/AND clauses spliced in below. A
        // top-level "all of" lists its rules directly (the flat case
        // reads as it always has); any other group gets a "Match ... of:"
        // line with its rules indented beneath it.
        if filter.root.match == .all {
            return filter.root.rules.flatMap { summaryLines($0, indent: "  ") }
        }
        return groupSummaryLines(filter.root, indent: "  ")
    }

    private static func summaryLines(_ rule: FilterRule, indent: String) -> [String] {
        switch rule {
        case .rating(let rating): return [indent + "Rating filter: \(describe(rating))"]
        case .category(let category): return [indent + "Category filter: \(describe(category))"]
        case .group(let group): return groupSummaryLines(group, indent: indent)
        }
    }

    private static func groupSummaryLines(_ group: RuleGroup, indent: String) -> [String] {
        let heading: String
        switch group.match {
        case .all: heading = "Match all of:"
        case .any: heading = "Match any of:"
        case .none: heading = "Match none of:"
        }
        return [indent + heading] + group.rules.flatMap { summaryLines($0, indent: indent + "  ") }
    }

    private static func describe(_ rating: RatingFilter) -> String {
        switch rating {
        case .exactly(let value): return "exactly \(value)"
        case .atLeast(let value): return "at least \(value)"
        case .atMost(let value): return "at most \(value)"
        }
    }

    private static func describe(_ category: CategoryFilter) -> String {
        let count = category.branches.count
        switch category.mode {
        case .any: return "any of \(count) categories (including subcategories)"
        case .all: return "all of \(count) categories (including subcategories)"
        case .none: return "none of \(count) categories (including subcategories)"
        }
    }

    // MARK: - The two dynamic CommandText assignments

    // Both methods below build their SQL text as one Swift string, then
    // escape it into a *single* Pascal string literal -- deliberately
    // never two adjacent literals joined by `+` (`'a' + 'b'`). Confirmed
    // by hand in Script Studio (see AGENTS.md) that this interpreter
    // rejects exactly that shape with a misleadingly-located "Syntax
    // error", even though the *identical* concatenation compiles fine
    // when one side is a variable instead of a literal (as
    // `ACandidates.CommaText` already is below) -- so a literal is only
    // ever `+`-joined with a variable here, never with another literal.
    private static func extentCommandTextLines(predicate: String?) -> [String] {
        var sql = "SELECT COUNT(*) AS RowCount, MAX(rowid) AS MaxRowID FROM idCatalogItem"
        if let predicate {
            sql += " WHERE " + predicate
        }
        return [
            "    AExtentSet.CommandText :=",
            "      \(PascalStringLiteral.escape(sql));",
        ]
    }

    private static func sampleCommandTextLines(predicate: String?) -> [String] {
        var trailer = ")"
        if let predicate {
            trailer += " AND " + predicate
        }
        return [
            "          ASampleSet.CommandText :=",
            "            'SELECT GUID FROM idCatalogItem WHERE rowid IN (' +",
            "            ACandidates.CommaText + \(PascalStringLiteral.escape(trailer));",
        ]
    }
}
