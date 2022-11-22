open Core
module Sexp = Sexplib.Sexp
module D = Decoders_sexplib.Decode
open D

let option_or_else f = function None -> f () | Some v -> Some v
let derr ?context fmt =
  Format.ksprintf (fun s -> Decoders.Error.make ?context s) fmt

let err ?context fmt =
  Format.ksprintf (fun s -> Error (Decoders.Error.make ?context s)) fmt

let singleton decoder : 'a decoder =
  function
    List [elt] -> decoder elt
  | context ->
    err ~context "expected singleton"

let alist decoder : (string * 'a) list decoder =
  list (function
      Sexp.List (Atom key :: vl) ->
      Result.map (decoder (Sexp.List vl)) ~f:(fun vl -> (key,vl))
    | context -> err ~context "expected assoc list"
  )

let tagged_list tag decoder : 'a decoder =
  function
  | List (Atom tag' :: contents) when String.equal tag tag' ->
    decoder (Sexp.List contents)
  | List (Atom tag' :: _) as context ->
    err ~context "expected tag %s, received %s" tag tag'
  | List (_ :: _) as context ->
    err ~context "expected tagged-list %s, received non-tag expression" tag
  | _ as context ->
    err ~context "expected tagged-list %s, received atom" tag

module KV = struct
  type (_, 'res) t =
    | [] : ('res, 'res) t
    | (::) : (string * 'a decoder) * ('b, 'res) t -> ('a -> 'b, 'res) t
end

let property_list decoder : (string * 'a) list decoder =
  function
  | List elts ->
    let (let+) x f = Result.bind ~f x in
    let rec loop acc = function
      | Sexp.Atom property :: Atom "#" :: vl :: rest ->
        let+ vl = decoder (Sexp.List [Atom "#"; vl]) in
        loop ((property, vl) :: acc) rest
      | Sexp.Atom property :: vl :: rest ->
        let+ vl = decoder vl in
        loop ((property, vl) :: acc) rest
      | [] -> Ok (List.rev acc)
      | context :: _ -> err ~context "property list had invalid form" in
    loop [] elts
  | _ as context ->
    err ~context "expected property list, received invalid form"

let property_list_opt decoder =
  let* kv = (property_list (maybe decoder)) in
  let kv = List.filter_map ~f:(function (k, Some vl) -> Some (k,vl) | _ -> None) kv in
  succeed kv

let typed_property_list ?(opts=[]) bindings f =
  let* kv = (property_list value) in
  let find = List.Assoc.find ~equal:String.equal kv in
  let init_opts_res =
    List.fold opts ~init:(Ok ()) ~f:(fun acc (k,cb) ->
      Result.bind acc ~f:(fun _ ->
        Option.map ~f:cb (find k)
        |> Option.value ~default:(Ok ())
      )
    ) in    
  match init_opts_res with
  | Error err -> from_result @@ Error err
  | Ok () ->
    let rec loop : type a b . (a, b) KV.t * a -> (b, value Decoders.Error.t) Result.t =
      function
      | KV.[], acc -> Ok acc
      | (key, decoder) :: rest, acc ->
        let vl =
          find key
          |> Result.of_option ~error:(derr "failed to find key %s" key)
          |> Result.bind ~f:decoder in
        match vl with
        | Error err -> Error err
        | Ok v -> loop (rest, (acc v)) in
    from_result @@ loop (bindings, f)

type pos = {
  begin_: int;
  end_: int;
}
[@@deriving show]

type property = { key: string; value: string; pos: pos}
[@@deriving show]

type tag = string
[@@deriving show]

type op = Italic | Strikethrough | Bold | Underline | Subscript | Superscript
[@@deriving show]

type txt =
  | Lit of string
  | Concat of txt list
  | Code of string | Verbatim of string
  | Entity of string
  | Format of op * txt
  | InlineSrcBlock of { language: string; value: string }  
[@@deriving show]

type time = { year: int; month: int; day: int; hour: int option; minute: int option }
[@@deriving show]

type timestamp = { raw: string; start: time; end_: time; pos: pos }
[@@deriving show]

type todo = {
  keyword: string;
  ty: [`Todo | `Done];
}
[@@deriving show]

type t =
  | Property of property
  | Section of { pos: pos; properties: t list}
  | Headline of {
      raw_value: string;
      title: txt;
      pos: pos;
      level: int;
      priority: int option;
      tags: tag list;
      todo: todo option;
      subsections: t list;
      closed: timestamp option;
      scheduled: timestamp option;
      deadline: timestamp option;
    }
  | Drawer of { name: string; pos: pos; contents: t list }
  | Clock of {
      status: [`running | `closed ];
      value: timestamp;
      duration: string option;
      pos: pos;
    }
  | Planning of {
      closed: timestamp option;
      scheduled: timestamp option;
      deadline: timestamp option;
      pos: pos;
    }
[@@deriving show]

let property =
  let* kv = tagged_list "keyword" (singleton (property_list_opt string)) in
  let find = List.Assoc.find ~equal:String.equal kv in
  match Option.all [find ":key"; find ":value"; find ":begin"; find ":end"] with
  | Some [key; value; begin_;end_] ->
    let begin_, end_ = Int.of_string begin_, Int.of_string end_ in
    succeed ({key;value; pos={begin_;end_}})
  | _ ->
    fail "invalid form for property list"

let cons decoder f = uncons f decoder

let nillable decoder = function
  | Sexp.Atom "nil" -> Ok None
  | sexp -> decoder sexp |> Result.map ~f:Option.some

let todo_keyword = function
  | Sexp.List [Atom "#"; List (Atom keyword :: _)] -> Ok keyword
  | context -> err ~context "expected literal text for todo keyword"

let todo_type = function
  | Sexp.Atom "todo" -> Ok `Todo
  | Sexp.Atom "done" -> Ok `Done
  | context -> err ~context "expected todo or done for todo-type"

let tags_list =
  function
  | Sexp.List elts ->
    let rec loop acc = function
      | Sexp.Atom "#" :: List (Atom tag :: _) :: rest ->
        loop (tag :: acc) rest
      | [] -> Ok (List.rev acc)
      | _ ->
        err  "expected list of literals for tags list" in
    loop [] elts
  | context ->
    err ~context "invalid structure for tags list"

let timestamp = function
  | Sexp.List (Atom "timestamp" :: prop_list :: []) ->
    typed_property_list KV.[
      ":raw-value", string;
      ":year-start", int;
      ":month-start", int;
      ":day-start", int;
      ":hour-start", nillable int;
      ":minute-start", nillable int;
      ":year-end", int;
      ":month-end", int;
      ":day-end", int;
      ":hour-end", nillable int;
      ":minute-end", nillable int;
      ":begin", int;
      ":end", int;
    ] (fun raw_value
        year_start month_start day_start hour_start minute_start
        year_end month_end day_end hour_end minute_end begin_ end_ ->
        {
          raw=raw_value;
          start={ year=year_start; month=month_start; day=day_start; hour=hour_start; minute=minute_start };
          end_={ year=year_end; month=month_end; day=day_end; hour=hour_end; minute=minute_end };
          pos={begin_;end_;}
        }        
      ) prop_list
  | context -> err ~context "invalid structure for timestamp"


let rec txt =
  let (let+) x f = Result.bind x ~f in
  function
  | Sexp.List (Atom "#" :: List (Atom txt :: _) :: []) -> Ok (Lit txt)
  | Sexp.List (Atom "strike-through" :: _ :: rest) ->
    let+ rest = txt (List rest) in
    Ok (Format (Strikethrough, rest))
  | Sexp.List (Atom "italic" :: _ :: rest) ->
    let+ rest = txt (List rest) in
    Ok (Format (Italic, rest))
  | Sexp.List (Atom "bold" :: _ :: rest) ->
    let+ rest = txt (List rest) in
    Ok (Format (Bold, rest))
  | Sexp.List (Atom "underline" :: _ :: rest) ->
    let+ rest = txt (List rest) in
    Ok (Format (Underline, rest))
  | Sexp.List (Atom "subscript" :: _ :: rest) ->
    let+ rest = txt (List rest) in
    Ok (Format (Subscript, rest))
  | Sexp.List (Atom "superscript" :: _ :: rest) ->
    let+ rest = txt (List rest) in
    Ok (Format (Superscript, rest))
  | Sexp.List (Atom "code" :: prop_list :: []) ->
    let+ prop_list = property_list_opt string prop_list in
    let+ value = List.Assoc.find ~equal:String.equal prop_list ":value"
                 |> Result.of_option
                      ~error:(derr "failed to find value binding for code") in
    Ok (Code value)
  | Sexp.List (Atom "verbatim" :: prop_list :: []) ->
    let+ prop_list = property_list_opt string prop_list in
    let+ value = List.Assoc.find ~equal:String.equal prop_list ":value"
                 |> Result.of_option
                      ~error:(derr "failed to find value binding for code") in
    Ok (Verbatim value)
  | Sexp.List (Atom "entity" :: prop_list :: []) ->
    let+ prop_list = property_list_opt string prop_list in
    let+ value = List.Assoc.find ~equal:String.equal prop_list ":html"
                 |> option_or_else (fun () ->
                   List.Assoc.find ~equal:String.equal prop_list ":utf-8")
                 |> option_or_else (fun () ->
                   List.Assoc.find ~equal:String.equal prop_list ":ascii")
                 |> option_or_else (fun () ->
                   List.Assoc.find ~equal:String.equal prop_list ":latex")
                 |> Result.of_option
                      ~error:(derr "failed to find encodable binding for entity") in
    Ok (Entity value)
  | Sexp.List (Atom "inline-src-block" :: prop_list :: []) ->
    let+ prop_list = property_list_opt string prop_list in
    let+ lang = List.Assoc.find ~equal:String.equal prop_list ":language"
                |> Result.of_option
                     ~error:(derr "failed to find language for inline-src-block") in
    let+ value = List.Assoc.find ~equal:String.equal prop_list ":value"
                 |> Result.of_option
                      ~error:(derr "failed to find value for inline-src-block") in
    Ok (InlineSrcBlock {language=lang;value})
  | Sexp.List elts ->
    let rec loop acc = function
      | Sexp.Atom "#" :: vl :: rest ->
        let+ binding = txt (Sexp.List [Atom "#"; vl]) in
        loop (binding :: acc) rest
      | vl :: rest ->
        let+ binding = txt vl in
        loop (binding :: acc) rest
      | [] -> Ok (Concat (List.rev acc)) in
    loop [] elts
  | context -> err ~context "expected literal sexp"

let section t =
  tagged_list "section" begin
    cons (property_list_opt string) @@ fun kv ->
    let find = List.Assoc.find ~equal:String.equal kv in
    let* properties = list_filter (maybe t) in
    match find ":begin", find ":end" with
    | Some begin_, Some end_ ->
      let begin_, end_ = Int.of_string begin_, Int.of_string end_ in
      succeed (Section {pos={begin_; end_}; properties})
    | _ -> fail "invalid form for section"
  end

let headline t =
  tagged_list "headline" begin
    let closed = ref None in
    let scheduled = ref None in
    let deadline = ref None in
    cons (
      typed_property_list
        ~opts:[
          ":closed", (fun vl -> Result.bind ((nillable timestamp) vl) ~f:(fun ts -> closed := ts; Ok ()));
          ":scheduled", (fun vl -> Result.bind ((nillable timestamp) vl)
                                     ~f:(fun ts -> scheduled := ts; Ok ()));
          ":deadline", fun vl -> Result.bind ((nillable timestamp) vl)
                                   ~f:(fun ts -> deadline := ts; Ok ())
        ]
        KV.[
          ":raw-value", string;
          ":begin", int; ":end", int;
          ":level", int;
          ":priority", nillable int;
          ":tags", nillable tags_list;
          ":todo-keyword", nillable todo_keyword;
          ":todo-type", nillable todo_type;
          ":title", txt
        ] (fun raw_value begin_ end_ level priority tags todo_keyword todo_type title ->
          let todo =
            Option.map ~f:(fun (keyword, ty) -> {keyword;ty}) @@
            Option.both todo_keyword todo_type in
          let tags = Option.value ~default:[] tags in
          let closed = !closed in
          let scheduled = !scheduled in
          let deadline = !deadline in
          fun subsections ->
            Headline {
              raw_value; title;
              pos={begin_; end_};
              level;
              priority;
              tags;
              todo;
              subsections;
              closed;
              scheduled;
              deadline;
            }
        )) (fun res ->
      let* children = list_filter (maybe t) in
      succeed (res children)
    )
  end


let drawer t =
  tagged_list "drawer" begin
    cons (
      typed_property_list
        KV.[
          ":begin", int; ":end", int;
          ":drawer-name", string;
        ] (fun begin_ end_ drawer_name ->
          fun contents ->
            Drawer {
              name=drawer_name;
              pos={begin_;end_};
              contents
            }
        )) (fun res ->
      let* children = list_filter (maybe t) in
      succeed (res children)
    )
  end

let clock_status = function
  | Sexp.Atom "running" -> Ok `running
  | Atom "closed" -> Ok `closed
  | context -> err ~context "invalid form for clock status"

let clock =
  tagged_list "clock" begin
    cons (
      typed_property_list
        KV.[
          ":status", clock_status;
          ":value", timestamp;
          ":duration", nillable string;
          ":begin", int; ":end", int;
        ] (fun status value duration begin_ end_ ->
          Clock {
            status;
            value;
            duration;
            pos={begin_;end_}
          }
        )) (fun res -> succeed res)
  end

let planning =
  tagged_list "planning" begin
    cons (
      typed_property_list
        KV.[
          ":closed", nillable timestamp;
          ":scheduled", nillable timestamp;
          ":deadline", nillable timestamp;
          ":begin", int; ":end", int;
        ] (fun closed scheduled deadline begin_ end_ ->
          Planning {
            closed;
            scheduled;
            deadline;
            pos={begin_;end_}
          }
        )) (fun res -> succeed res)
  end

let t =
  fix (fun t ->
    one_of [
      "property", property >|= (fun prop -> Property prop);
      "clock", clock;
      "planning", planning;
      "section", section t;
      "headline", headline t;
      "drawer", drawer t;
    ]
  )

let section = section t
let headline = headline t
let drawer = drawer t

let org_data =
  tagged_list "org-data" begin
    uncons (fun _ -> list_filter (maybe t)) value
  end

let org_buffer_data = alist org_data

let run decoder s = D.decode_value decoder s
  