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
            "",
            "// Returns up to ACount uniformly random catalog item GUIDs.",
            "//",
            "// Draws random rowids in [1, MAX(rowid)] and keeps the ones that still",
            "// exist, instead of the old ORDER BY RANDOM() LIMIT N (which touches",
            "// every live row to fill its top-N heap). Benchmarked against the real",
            "// catalog with sqlite3: about 0.38s for ORDER BY RANDOM() LIMIT 10000",
            "// vs about 0.04s for this approach, both returning 10,000 rows.",
            "//",
            "// The oversample factor is computed from the current row count and max",
            "// rowid rather than hardcoded, since deletions widen that gap over",
            "// time. A retry loop tops up any shortfall.",
            "//",
            "// No try/except here: this interpreter does not appear to support it",
            "// (try/finally does). If PublicCatalog.NewDataSet or FieldValue raises",
            "// partway through, result is orphaned rather than freed -- acceptable",
            "// on an already-abnormal path, and consistent with the rest of the file.",
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
            "        // Random takes no parameters here (returns Extended in [0,1));",
            "        // scale it into [1, AMaxRowID] ourselves.",
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
            "      // Drop the temp-list rows again; they are only needed for the",
            "      // enumeration above and would otherwise accumulate in idTempList.",
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
            "  // AData.Data is TObject in the public API and its concrete class isn't",
            "  // documented anywhere, but Variant works: confirmed by running this",
            "  // script, which resolves AColl.Clear / AColl.Items._DataSets via",
            "  // late-bound dispatch.",
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
            "    // Take over the dataset(s) for extra performance.",
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
        // logic lives in the WHERE/AND clauses spliced in below.
        var lines: [String] = []
        if let rating = filter.rating {
            lines.append("  Rating filter: \(describe(rating))")
        }
        if let category = filter.category {
            lines.append("  Category filter: \(describe(category))")
        }
        return lines
    }

    private static func describe(_ rating: RatingFilter) -> String {
        switch rating {
        case .exactly(let value): return "exactly \(value)"
        case .atLeast(let value): return "at least \(value)"
        case .atMost(let value): return "at most \(value)"
        }
    }

    private static func describe(_ category: CategoryFilter) -> String {
        switch category.mode {
        case .any: return "any of \(category.propGUIDs.count) categories"
        case .all: return "all of \(category.propGUIDs.count) categories"
        case .none: return "none of \(category.propGUIDs.count) categories"
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
