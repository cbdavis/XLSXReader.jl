__precompile__()
module XLSXReader
using ZipFile, LightXML, DataArrays, DataFrames

immutable WorkSheet
    name::String
    id::Int64
end

export readxlsx

#sheets = filter(x-> contains(x, "xl/worksheets/"), fnames)
function get_sharedstrings(file::String)
  xlfile = ZipFile.Reader(file)
  fnames = [x.name for x in xlfile.files]
  sidx = find(fnames .== "xl/sharedStrings.xml")
  shared = []
  if !isempty(sidx)
      doc = readstring(xlfile.files[sidx[1]])
      xdoc = parse_string(doc)
      xroot = root(xdoc)  # an instance of XMLElement
      shared = []
      for si in get_elements_by_tagname(xroot, "si")
          t = find_element(si, "t")
          if t != nothing
              push!(shared, content(t))
          else
              rs = get_elements_by_tagname(si, "r")
              res = ""
              for r in rs
                  res *= content(find_element(r, "t"))
              end
              push!(shared, res)
          end
      end
  end
  return(shared)
end

function xlsx_parsexml(xslxfile::String, xmlfile::String)
  xlfile = ZipFile.Reader(xslxfile);
  fnames = [x.name for x in xlfile.files]
  wb_idx = find(fnames .== xmlfile)
  xml = readstring(xlfile.files[wb_idx[1]])
  close(xlfile)
  return parse_string(xml)
end

function get_styles(file::String)
  styles = root(xlsx_parsexml(file, "xl/styles.xml"))
  cellXfs = find_element(styles, "cellXfs")
  xfs = get_elements_by_tagname(cellXfs, "xf")
  styledict = attributes_dict.(xfs)
  free(styles)
  return styledict
end

function get_worksheets(file::String)
    xml = xlsx_parsexml(file, "xl/workbook.xml")
    wbook = root(xml)
    sheets = find_element(wbook, "sheets")
    sheets = get_elements_by_tagname(sheets, "sheet")

    wsheets = WorkSheet[]
    for sheet in sheets
        sid = parse(Int64, attribute(sheet, "sheetId"))
        push!(wsheets, WorkSheet(attribute(sheet, "name"), sid))
    end
    free(wbook)
    return(wsheets)
end


function format_cellnumber(value)
    if contains(value, ".")
        return parse(Float64, value)
    else
        return parse(Int64, value)
    end
end

function formatcell(c, styles)
    value = content(find_element(c, "v"))
    nvalue = format_cellnumber(value)
    cs = attribute(c, "s")
    cs == nothing && return nvalue

    sidx = parse(Int64, cs)
    fmt = parse(Int64, styles[sidx + 1]["numFmtId"])

    # ECMA part 1: 18.8.30 numFmt (Number Format)
    # 14-22 are date formats
    if fmt ≥ 14 && fmt ≤ 22 #Date
        return DateTime(Dates.unix2datetime((nvalue - 25569) * 86400))
    else
        return nvalue
    end
end

function readrow(row, shared_strings, styles)
  res = Dict()
  maxcol = 1
  # Iterate cols from a row
  for c in collect(child_elements(row))
    cr = attribute(c, "r") #Column and row
    col = replace(cr, r"[0-9]", "") #Just column
    value = ""
    maxcol = max(maxcol, colnum(col))
    if has_children(c)
        if !has_attribute(c, "t")
            res[col] = formatcell(c, styles)
            continue
        end

        ct = attribute(c, "t")
        if ct == "s"
            value = content(find_element(c, "v"))
            idx = parse(Int64, value)
            value = shared_strings[idx + 1]
        end
    end

    res[col] = value
  end
  return(res, maxcol)
end

function readxlsx(file::String, sheet::Int=1; header = true, skip = 0)
    wsheets = get_worksheets(file)
    readxlsx(file, wsheets[sheet].name, header = header, skip = skip)
end

function readxlsx(file::String, sheet::String; header = true, skip = 0)
    wsheets = get_worksheets(file)
    shared_strings = get_sharedstrings(file)
    styles = get_styles(file)

    sid = filter(x -> x.name == sheet, wsheets)[1].id
    xdoc = xlsx_parsexml(file, "xl/worksheets/sheet$sid.xml")
    xroot = root(xdoc)  # an instance of XMLElement
    rows = find_element(xroot, "sheetData")

    rowres = []
    maxcol = 1
    for row in child_elements(rows)
        vals, rowmax = readrow(row, shared_strings, styles)
        push!(rowres, vals)
        maxcol = max(maxcol, rowmax)
    end
    free(xdoc)
    wsarray = ws2array(rowres, maxcol)
    df = wsarray2df(wsarray, skip = skip, header = header)
    return(df)
end

#From ExcelReaders.jl
function colnum(col::AbstractString)
    cl=uppercase(col)
    r=0
    for c in cl
        r = (r * 26) + (c - 'A' + 1)
    end
    return r
end

function ws2array(cells, ncols::Int)
    n = length(cells)
    wsarray = DataArray(Any, n, ncols)
    for i in 1:n
        row = cells[i]
        for k in keys(row)
            wsarray[i, colnum(k)] = row[k]
        end
    end
    return wsarray
end

"""Create valid DataFrame column name from header string"""
function make_colname(name::String)
    name = replace(name, ".", "")
    name = replace(name, r"\s", "")
    if ismatch(r"^[1-9]", name)
        name = "x" * name
    end
    return Symbol(name)
end

function wsarray2df(wsarray; skip::Int = 0, header::Bool = true)
    df = DataFrame()
    ncols = size(wsarray)[2]

    if header
        colnames = make_colname.(wsarray[1+skip,:])
    else
        colnames = Symbol.(["x"] .* string.(1:ncols))
    end

    for i in 1:ncols
        df[colnames[i]] = wsarray[(1+skip+Int(header):end) ,i]
    end
    return df
end

end
