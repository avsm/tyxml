(* TyXML
 * http://www.ocsigen.org/tyxml
 * Copyright (C) 2016 Anton Bachin
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Suite 500, Boston, MA 02111-1307, USA.
*)

open Asttypes

(* Not opening all of Ast_helper in order to avoid shadowing stdlib's Str with
   Ast_helper.Str. *)
module Exp = Ast_helper.Exp



type parser =
  ?separated_by:string -> ?default:string -> Location.t -> string -> string ->
    Parsetree.expression option



(* Options. *)

let option none (parser : parser) ?separated_by:_ ?default:_ loc name s =
  if s = none then Some [%expr None] [@metaloc loc]
  else
    match parser ~default:none loc name s with
    | None -> None
    | Some e -> Some [%expr Some [%e e]] [@metaloc loc]



(* Lists. *)

let _filter_map f l =
  l
  |> List.fold_left (fun acc v ->
    match f v with
    | None -> acc
    | Some v' -> v'::acc)
    []
  |> List.rev

(* Splits the given string on the given delimiter (a regular expression), then
   applies [element_parser] to each resulting component. Each such application
   resulting in [Some expr] is included in the resulting expression list. *)
let _exp_list delimiter separated_by (element_parser : parser) loc name s =
  Str.split delimiter s
  |> _filter_map (element_parser ~separated_by loc name)

(* Behaves as _expr_list, but wraps the resulting expression list as a list
   expression. *)
let _list
    delimiter separated_by element_parser ?separated_by:_ ?default:_ loc name s =

  _exp_list delimiter separated_by element_parser loc name s
  |> Ppx_common.list_exp loc
  |> fun e -> Some e

let spaces = _list (Str.regexp " +") "space"
let commas = _list (Str.regexp " *, *") "comma"
let semicolons = _list (Str.regexp " *; *") "semicolon"

let _spaces_or_commas_regexp = Str.regexp "\\( *, *\\)\\| +"
let _spaces_or_commas = _exp_list _spaces_or_commas_regexp "space- or comma"
let spaces_or_commas = _list _spaces_or_commas_regexp "space- or comma"



(* Wrapping. *)

let wrap (parser : parser) implementation ?separated_by:_ ?default:_ loc name s =
  match parser loc name s with
  | None -> Ppx_common.error loc "wrap applied to presence; nothing to wrap"
  | Some e -> Some (Ppx_common.wrap_exp implementation loc e)

let nowrap (parser : parser) _ ?separated_by:_ ?default:_ loc name s =
  parser loc name s



(* Error reporting for values in lists and options. *)

let _must_be_a
    singular_description plural_description separated_by default loc name =

  let description =
    match separated_by with
    | Some separated_by ->
      Printf.sprintf "a %s-separated list of %s" separated_by plural_description
    | None ->
      match default with
      | Some default -> Printf.sprintf "%s or %s" singular_description default
      | None -> singular_description
  in

  Ppx_common.error loc "Value of %s must be %s" name description



(* General helpers. *)

(* Checks that the given string matches the given regular expression exactly,
   i.e. the match begins at position 0 and ends at the end of the string. *)
let _does_match regexp s =
  Str.string_match regexp s 0 && Str.match_end () = String.length s

(* Checks that the group with the given index was matched in the given
   string. *)
let _group_matched index s =
  try Str.matched_group index s |> ignore; true
  with Not_found -> false

let _int_exp loc s =
  try Some (Ppx_common.int_exp loc (int_of_string s))
  with Failure "int_of_string" -> None

let _float_exp loc s =
  try
    float_of_string s |> ignore;
    Some (Ppx_common.float_exp loc s)
  with Failure "float_of_string" ->
    None



(* Numeric. *)

let char ?separated_by:_ ?default:_ loc name s =
  let open Markup in
  let open Markup.Encoding in

  let report _ error =
    Ppx_common.error loc "%s in attribute %s"
      (Markup.Error.to_string error |> String.capitalize) name
  in
  let decoded = string s |> decode ~report utf_8 in

  let c =
    match next decoded with
    | None -> Ppx_common.error loc "No character in attribute %s" name
    | Some i ->
      try Char.chr i
      with Invalid_argument "Char.chr" ->
        Ppx_common.error loc "Character out of range in attribute %s" name
  in

  begin match next decoded with
  | None -> ()
  | Some _ -> Ppx_common.error loc "Multiple characters in attribute %s" name
  end;

  Some (Exp.constant ~loc (Const_char c))

let bool ?separated_by:_ ?default:_ loc name s =
  begin
    try bool_of_string s |> ignore
    with Invalid_argument "bool_of_string" ->
      Ppx_common.error loc "Value of %s must be \"true\" or \"false\"" name
  end;

  Some (Exp.construct ~loc (Location.mkloc (Longident.parse s) loc) None)

let int ?separated_by ?default loc name s =
  match _int_exp loc s with
  | Some _ as e -> e
  | None ->
    _must_be_a "a whole number" "whole numbers" separated_by default loc name

let float ?separated_by ?default loc name s =
  match _float_exp loc s with
  | Some _ as e -> e
  | None ->
    _must_be_a
      "a number (decimal fraction)" "numbers (decimal fractions)"
      separated_by default loc name

let points ?separated_by:_ ?default:_ loc name s =
  let expressions = _spaces_or_commas float loc name s in

  let rec pair acc = function
    | [] -> List.rev acc |> Ppx_common.list_exp loc
    | [_] -> Ppx_common.error loc "Unpaired coordinate in %s" name
    | ex::ey::rest -> pair (([%expr [%e ex], [%e ey]] [@metaloc loc])::acc) rest
  in

  Some (pair [] expressions)

let number_pair ?separated_by:_ ?default:_ loc name s =
  let e =
    begin match _spaces_or_commas float loc name s with
    | [orderx] -> [%expr [%e orderx], None]
    | [orderx; ordery] -> [%expr [%e orderx], Some [%e ordery]]
    | _ -> Ppx_common.error loc "%s requires one or two numbers" name
    end [@metaloc loc]
  in

  Some e

let fourfloats ?separated_by:_ ?default:_ loc name s =
  match _spaces_or_commas float loc name s with
  | [min_x; min_y; width; height] ->
    Some [%expr ([%e min_x], [%e min_y], [%e width], [%e height])]
      [@metaloc loc]
  | _ -> Ppx_common.error loc "Value of %s must be four numbers" name

(* These are always in a list; hence the error message. *)
let icon_size =
  let regexp = Str.regexp "\\([0-9]+\\)[xX]\\([0-9]+\\)" in

  fun ?separated_by:_ ?default:_ loc name s ->
    if not @@ _does_match regexp s then
      Ppx_common.error loc "Value of %s must be a %s, or %s"
        name "space-separated list of icon sizes, such as 16x16" "any";

    let width, height =
      try
        int_of_string (Str.matched_group 1 s),
        int_of_string (Str.matched_group 2 s)
      with Invalid_argument "int_of_string" ->
        Ppx_common.error loc "Icon dimension out of range in %s" name
    in

    Some
      [%expr
        [%e Ppx_common.int_exp loc width],
        [%e Ppx_common.int_exp loc height]] [@metaloc loc]



(* Dimensional. *)

let length =
  let regexp = Str.regexp "\\([0-9]+\\)\\([^0-9]+\\)" in

  fun ?separated_by:_ ?default:_ loc name s ->
    if not @@ _does_match regexp s then
      Ppx_common.error
        loc "Value of %s must be a length, such as 100px or 50%%" name;

    let n =
      match _int_exp loc (Str.matched_group 1 s) with
      | Some n -> n
      | None ->
        Ppx_common.error loc "Value of %s out of range" name
    in

    let e =
      begin match Str.matched_group 2 s with
      | "%" -> [%expr `Percent [%e n]]
      | "px" -> [%expr `Pixels [%e n]]
      | unit -> Ppx_common.error loc "Unknown unit %s in %s" unit name
      end [@metaloc loc]
    in

    Some e

(* This is only called by the commas combinator; hence the error message. *)
let multilength =
  let regexp = Str.regexp "\\([0-9]+\\)\\(%\\|px\\)\\|\\([0-9]+\\)?\\*" in

  fun ?separated_by:_ ?default:_ loc name s ->
    if not @@ _does_match regexp s then
      Ppx_common.error loc "Value of %s must be a %s"
        name "list of relative lengths, such as 100px, 50%, or *";

    begin
      if _group_matched 1 s then
        let n =
          match _int_exp loc (Str.matched_group 1 s) with
          | Some n -> n
          | None ->
            Ppx_common.error loc "Value in %s out of range" name
        in

        match Str.matched_group 2 s with
        | "%" -> Some [%expr `Percent [%e n]]
        | "px" -> Some [%expr `Pixels [%e n]]
        | _ -> Ppx_common.error loc "Internal error: Ppx_attribute.multilength"

      else
        let n =
          match _int_exp loc (Str.matched_group 3 s) with
          | exception Not_found -> [%expr 1]
          | Some n -> n
          | None ->
            Ppx_common.error loc "Relative length in %s out of range" name
        in

        Some [%expr `Relative [%e n]]
    end [@metaloc loc]

let _svg_quantity =
  let integer = "[+-]?[0-9]+" in
  let integer_scientific = Printf.sprintf "%s\\([Ee]%s\\)?" integer integer in
  let fraction = Printf.sprintf "[+-]?[0-9]*\\.[0-9]+\\([Ee]%s\\)?" integer in
  let number = Printf.sprintf "%s\\|%s" integer_scientific fraction in
  let quantity = Printf.sprintf "\\(%s\\)\\([^0-9]*\\)$" number in
  let regexp = Str.regexp quantity in

  fun kind_singular kind_plural parse_unit ?separated_by ?default loc name s ->
    if not @@ _does_match regexp s then
      _must_be_a kind_singular kind_plural separated_by default loc name;

    let n =
      match _float_exp loc (Str.matched_group 1 s) with
      | Some n -> n
      | None -> Ppx_common.error loc "Number out of range in %s" name
    in

    let unit_string = Str.matched_group 4 s in
    let unit =
      (if unit_string = "" then [%expr None]
      else [%expr Some [%e parse_unit loc name unit_string]]) [@metaloc loc]
    in

    [%expr [%e n], [%e unit]] [@metaloc loc]

let svg_length =
  let parse_unit loc name unit =
    begin match unit with
    | "cm" -> [%expr `Cm]
    | "em" -> [%expr `Em]
    | "ex" -> [%expr `Ex]
    | "in" -> [%expr `In]
    | "mm" -> [%expr `Mm]
    | "pc" -> [%expr `Pc]
    | "pt" -> [%expr `Pt]
    | "px" -> [%expr `Px]
    | "%" -> [%expr `Percent]
    | s -> Ppx_common.error loc "Invalid length unit %s in %s" s name
    end [@metaloc loc]
  in

  fun ?separated_by ?default loc name s ->
    Some
      (_svg_quantity "an SVG length" "SVG lengths" parse_unit
        ?separated_by ?default loc name s)

let _angle =
  let parse_unit loc name unit =
    begin match unit with
    | "deg" -> [%expr `Deg]
    | "rad" -> [%expr `Rad]
    | "grad" -> [%expr `Grad]
    | s -> Ppx_common.error loc "Invalid angle unit %s in %s" s name
    end [@metaloc loc]
  in

  _svg_quantity "an SVG angle" "SVG angles" parse_unit

let angle ?separated_by ?default loc name s =
  Some (_angle ?separated_by ?default loc name s)

let offset =
  let bad_form name loc =
    Ppx_common.error loc "Value of %s must be a number or percentage" name in

  let regexp = Str.regexp "\\([-+0-9eE.]+\\)$\\|\\([0-9]+\\)%" in

  fun ?separated_by:_ ?default:_ loc name s ->
    if not @@ _does_match regexp s then bad_form name loc;

    begin
      if _group_matched 1 s then
        let n =
          match _float_exp loc s with
          | Some n -> n
          | None -> bad_form name loc
        in

        Some [%expr `Number [%e n]]

      else
        let n =
          match _int_exp loc (Str.matched_group 2 s) with
          | Some n -> n
          | None ->
            Ppx_common.error loc "Percentage out of range in %s" name
        in

        Some [%expr `Percentage [%e n]]
    end [@metaloc loc]

let transform =
  let regexp = Str.regexp "\\([^(]+\\)(\\([^)]*\\))" in

  fun ?separated_by:_ ?default:_ loc name s ->
    if not @@ _does_match regexp s then
      Ppx_common.error loc "Value of %s must be an SVG transform" name;

    let kind = Str.matched_group 1 s in
    let values = Str.matched_group 2 s in

    let e =
      begin match kind with
      | "matrix" ->
        begin match _spaces_or_commas float loc "matrix" values with
        | [a; b; c; d; e; f] ->
          [%expr Svg_types.Matrix
            ([%e a], [%e b], [%e c], [%e d], [%e e], [%e f])]
        | _ ->
          Ppx_common.error loc "%s: matrix requires six numbers" name
        end

      | "translate" ->
        begin match _spaces_or_commas float loc "translate" values with
        | [tx; ty] -> [%expr Svg_types.Translate ([%e tx], Some [%e ty])]
        | [tx] -> [%expr Svg_types.Translate ([%e tx], None)]
        | _ ->
          Ppx_common.error loc "%s: translate requires one or two numbers" name
        end

      | "scale" ->
        begin match _spaces_or_commas float loc "scale" values with
        | [sx; sy] -> [%expr Svg_types.Scale ([%e sx], Some [%e sy])]
        | [sx] -> [%expr Svg_types.Scale ([%e sx], None)]
        | _ ->
          Ppx_common.error loc "%s: scale requires one or two numbers" name
        end

      | "rotate" ->
        begin match Str.bounded_split _spaces_or_commas_regexp values 2 with
        | [angle] ->
          [%expr Svg_types.Rotate ([%e _angle loc "rotate" angle], None)]
        | [angle; axis] ->
          begin match _spaces_or_commas float loc "rotate axis" axis with
          | [cx; cy] ->
            [%expr Svg_types.Rotate
              ([%e _angle loc "rotate" angle], Some ([%e cx], [%e cy]))]
          | _ ->
            Ppx_common.error loc "%s: rotate center requires two numbers" name
          end
        | _ ->
          Ppx_common.error loc
            "%s: rotate requires an angle and an optional center" name
        end

      | "skewX" -> [%expr Svg_types.SkewX [%e _angle loc "skewX" values]]

      | "skewY" -> [%expr Svg_types.SkewY [%e _angle loc "skewY" values]]

      | s -> Ppx_common.error loc "%s: %s is not a valid transform type" name s
      end [@metaloc loc]
    in

    Some e



(* String-like. *)

let string ?separated_by:_ ?default:_ loc _ s =
  Some (Exp.constant ~loc (Const_string (s, None)))

let _variand s =
  let without_backtick s =
    let length = String.length s in
    String.sub s 1 (length - 1)
  in

  s |> Tyxml_name.polyvar |> without_backtick

let variant ?separated_by:_ ?default:_ loc _ s =
  Some (Exp.variant ~loc (_variand s) None)

let total_variant (unary, nullary) ?separated_by:_ ?default:_ loc _name s =
  let variand = _variand s in
  if List.mem variand nullary then Some (Exp.variant ~loc variand None)
  else Some (Exp.variant ~loc unary (Some (Ppx_common.string_exp loc s)))



(* Miscellaneous. *)

let presence ?separated_by:_ ?default:_ _ _ _ = None

let _paint_without_icc loc _name s =
  begin match s with
  | "none" ->
    [%expr `None]

  | "currentColor" ->
    [%expr `CurrentColor]

  | _ ->
    let icc_color_start =
      try Some (Str.search_forward (Str.regexp "icc-color(\\([^)]*\\))") s 0)
      with Not_found -> None
    in

    match icc_color_start with
    | None -> [%expr `Color ([%e Ppx_common.string_exp loc s], None)]
    | Some i ->
      let icc_color = Str.matched_group 1 s in
      let color = String.sub s 0 i in
      [%expr `Color
        ([%e Ppx_common.string_exp loc color],
         Some [%e Ppx_common.string_exp loc icc_color])]
  end [@metaloc loc]

let paint ?separated_by:_ ?default:_ loc name s =
  if not @@ Str.string_match (Str.regexp "url(\\([^)]+\\))") s 0 then
    Some (_paint_without_icc loc name s)
  else
    let iri = Str.matched_group 1 s |> Ppx_common.string_exp loc in
    let remainder_start = Str.group_end 0 in
    let remainder_length = String.length s - remainder_start in
    let remainder =
      String.sub s remainder_start remainder_length |> String.trim in

    begin
      if remainder = "" then
        Some [%expr `Icc ([%e iri], None)]
      else
        Some
          [%expr
            `Icc ([%e iri], Some [%e _paint_without_icc loc name remainder])]
    end [@metaloc loc]

let srcset_element =
  let space = Str.regexp " +" in

  fun ?separated_by:_ ?default:_ loc name s ->
    let e =
      begin match Str.bounded_split space s 2 with
      | [url] ->
        [%expr `Url [%e Ppx_common.string_exp loc url]]

      | [url; descriptor] ->
        let bad_descriptor () =
          Ppx_common.error loc "Bad width or density descriptor in %s" name in

        let url = Ppx_common.string_exp loc url in
        let suffix_index = String.length descriptor - 1 in

        let is_width =
          match descriptor.[suffix_index] with
          | 'w' -> true
          | 'x' -> false
          | _ -> bad_descriptor ()
          | exception Invalid_argument _ -> bad_descriptor ()
        in

        if is_width then
          let n =
            match _int_exp loc (String.sub descriptor 0 suffix_index) with
            | Some n -> n
            | None ->
              Ppx_common.error loc "Bad number for width in %s" name
          in

          [%expr `Url_width ([%e url], [%e n])]

        else
          let n =
            match _float_exp loc (String.sub descriptor 0 suffix_index) with
            | Some n -> n
            | None ->
              Ppx_common.error loc "Bad number for pixel density in %s" name
          in

          [%expr `Url_pixel ([%e url], [%e n])]

      | _ -> Ppx_common.error loc "Missing URL in %s" name
      end [@metaloc loc]
    in

    Some e



(* Special-cased. *)

let sandbox = spaces variant

let in_ = total_variant Svg_types_reflected.in_value

let in2 = in_

let xmlns ?separated_by:_ ?default:_ loc name s =
  if s <> Markup.Ns.html then
    Ppx_common.error loc "%s: namespace must be %s" name Markup.Ns.html;

  Some [%expr `W3_org_1999_xhtml] [@metaloc loc]
