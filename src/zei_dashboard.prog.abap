*&---------------------------------------------------------------------*
*& Report ZEI_DASHBOARD
*&---------------------------------------------------------------------*
*& E-Invoice Dashboard (UAE PINT AE - 5-corner model)
*& - KPI tiles: total, accepted by FTA, in process, needs action, error rate
*& - Status breakdown donut with drill-down list (double-click -> VF03)
*& - E-Invoice journey: documents currently at each corner
*& Data source: ZI_EINVOICE_HEADER (same as ZEI_UAE_INV_COCKPIT), read-only
*& Transaction : ZEI_DASHBOARD
*& UI: filters and dashboard are both in one full-screen HTML page
*&     (Go / Reset / Refresh via SAPEVENT; works in SAP GUI + WebGUI)
*&---------------------------------------------------------------------*
REPORT zei_dashboard.

TABLES: vbrk, knb1, sscrfields.

"Filters are entered in the HTML dashboard; these hidden ranges hold them
SELECT-OPTIONS: s_bukrs FOR vbrk-bukrs NO-DISPLAY,
                s_erdat FOR vbrk-erdat NO-DISPLAY.
PARAMETERS: p_btype TYPE knb1-zzbusinesstype NO-DISPLAY,
            p_type  TYPE zde_ei_type NO-DISPLAY,
            p_land  TYPE land1 NO-DISPLAY.
"Technical host field - hidden at runtime (screen 1000 must have one field
"to be generated; it only carries the docked HTML dashboard)
PARAMETERS: p_host TYPE c LENGTH 1 MODIF ID hid.


*----------------------------------------------------------------------*
* CLASS lcl_dash DEFINITION
*----------------------------------------------------------------------*
CLASS lcl_dash DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES: BEGIN OF ty_row,
             companycode      TYPE zi_einvoice_header-companycode,
             sapdocument      TYPE zi_einvoice_header-sapdocument,
             einvoicetype     TYPE zi_einvoice_header-einvoicetype,
"             doccategory      TYPE zi_einvoice_header-documentcategory,
             doctypetext      TYPE char20,
             fiscalyear       TYPE zi_einvoice_header-fiscalyear,
             creationdate     TYPE zi_einvoice_header-creationdate,
             customername     TYPE zi_einvoice_header-customername,
             totalvalue       TYPE zi_einvoice_header-totalvalue,
             currency         TYPE zi_einvoice_header-currency,
             statustext       TYPE char40,
             einvoicestatus   TYPE zi_einvoice_header-einvoicestatus,
             messagetype      TYPE zi_einvoice_header-messagetype,
             "Separate corner statuses (ZEINVOICE_DETAIL, same as ZEI_UAE_INV_COCKPIT)
             zzc1_status      TYPE zeinvoice_detail-zzc1_status,
             zzc2_status      TYPE zeinvoice_detail-zzc2_status,
             zzc3_sent_status TYPE zeinvoice_detail-zzc3_sent_status,
             zzc3_ack_status  TYPE zeinvoice_detail-zzc3_ack_status,
             zzc4_status      TYPE zeinvoice_detail-zzc4_status,
             zzc5_rep_status  TYPE zeinvoice_detail-zzc5_rep_status,
             zzc5_ack_status  TYPE zeinvoice_detail-zzc5_ack_status,
             zzoverall_status TYPE zeinvoice_detail-zzoverall_status,
             cornertext       TYPE string,
             bucket           TYPE i,
           END OF ty_row,
           tt_row TYPE STANDARD TABLE OF ty_row WITH EMPTY KEY.

    CONSTANTS: BEGIN OF gc_b,
                 completed TYPE i VALUE 1,
                 inprocess TYPE i VALUE 2,
                 notsent   TYPE i VALUE 3,
                 failed    TYPE i VALUE 4,
                 rejected  TYPE i VALUE 5,
                 duplicate TYPE i VALUE 6,
               END OF gc_b.

    DATA mv_action TYPE string READ-ONLY.

    METHODS: run,
      free,
      handle_action IMPORTING iv_action TYPE csequence,
      on_sapevent FOR EVENT sapevent OF cl_gui_html_viewer
        IMPORTING action getdata query_table.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_opt,
             value TYPE string,
             text  TYPE string,
           END OF ty_opt,
           tt_opt TYPE STANDARD TABLE OF ty_opt WITH EMPTY KEY,
           BEGIN OF ty_kv,
             name  TYPE string,
             value TYPE string,
           END OF ty_kv,
           tt_kv TYPE STANDARD TABLE OF ty_kv WITH EMPTY KEY.

    DATA: mv_filter     TYPE string VALUE 'ALL',
          mv_list_title TYPE string,
          mv_scroll     TYPE abap_bool.

    DATA: mt_opt_bt TYPE tt_opt,
          mt_opt_ty TYPE tt_opt,
          mt_opt_cc TYPE tt_opt,
          mt_opt_ld TYPE tt_opt,
          mv_opt    TYPE abap_bool.

    METHODS: load_options,
      apply_filters IMPORTING it_kv TYPE tt_kv,
      options_html IMPORTING it_opt    TYPE tt_opt
                             iv_sel    TYPE csequence
                   RETURNING VALUE(rv) TYPE string,
      to_date IMPORTING iv        TYPE string
              RETURNING VALUE(rv) TYPE d,
      iso IMPORTING iv        TYPE d
          RETURNING VALUE(rv) TYPE string.

    TYPES: BEGIN OF ty_bucket,
             id    TYPE i,
             label TYPE string,
             descr TYPE string,
             color TYPE string,
             count TYPE i,
           END OF ty_bucket,
           tt_bucket TYPE STANDARD TABLE OF ty_bucket WITH EMPTY KEY,
           ty_line   TYPE c LENGTH 255,
           tt_line   TYPE STANDARD TABLE OF ty_line WITH EMPTY KEY.

    DATA: mo_dock    TYPE REF TO cl_gui_docking_container,
          mo_html    TYPE REF TO cl_gui_html_viewer,
          mt_rows    TYPE tt_row,
          mt_list    TYPE tt_row,
          mt_buckets TYPE tt_bucket,
          mt_corner  TYPE STANDARD TABLE OF i WITH EMPTY KEY,
          mv_html    TYPE string,
          mv_time    TYPE string.

    METHODS: get_data,
      classify,
      build_html,
      show_html,
      add IMPORTING iv TYPE csequence,
      pct IMPORTING iv_part   TYPE i
                    iv_total  TYPE i
          RETURNING VALUE(rv) TYPE string,
      esc IMPORTING iv        TYPE csequence
          RETURNING VALUE(rv) TYPE string,
      filter_text RETURNING VALUE(rv) TYPE string,
      tile IMPORTING iv_action TYPE string
                     iv_label  TYPE string
                     iv_value  TYPE string
                     iv_sub    TYPE string
                     iv_color  TYPE string,
      show_list IMPORTING iv_filter TYPE string.
ENDCLASS.

*----------------------------------------------------------------------*
* CLASS lcl_dash IMPLEMENTATION
*----------------------------------------------------------------------*
CLASS lcl_dash IMPLEMENTATION.

  METHOD run.
    IF mv_opt = abap_false.
      load_options( ).
      mv_opt = abap_true.
    ENDIF.
    get_data( ).
    classify( ).
    build_html( ).
    show_html( ).
  ENDMETHOD.

  METHOD free.
    IF mo_html IS BOUND.
      mo_html->free( ).
      FREE mo_html.
      IF mo_dock IS BOUND.
        mo_dock->free( ).
        FREE mo_dock.
      ENDIF.
      cl_gui_cfw=>flush( ).
    ENDIF.
  ENDMETHOD.

  METHOD get_data.
    DATA: lr_btype TYPE RANGE OF knb1-zzbusinesstype,
          lr_type  TYPE RANGE OF zde_ei_type,
          lr_land  TYPE RANGE OF bukrs,
          lt_bukrs TYPE SORTED TABLE OF bukrs WITH UNIQUE KEY table_line.

    IF p_btype IS NOT INITIAL.
      lr_btype = VALUE #( ( sign = 'I' option = 'EQ' low = p_btype ) ).
    ENDIF.
    IF p_type IS NOT INITIAL.
      lr_type = VALUE #( ( sign = 'I' option = 'EQ' low = p_type ) ).
    ENDIF.

    IF p_land IS NOT INITIAL.
      SELECT bukrs FROM zeinv_company
        WHERE land1 = @p_land
        INTO TABLE @DATA(lt_lb).
      lr_land = VALUE #( FOR b IN lt_lb ( sign = 'I' option = 'EQ' low = b-bukrs ) ).
      IF lr_land IS INITIAL.        "country has no company -> match nothing
        lr_land = VALUE #( ( sign = 'E' option = 'CP' low = '*' ) ).
      ENDIF.
    ENDIF.

    CLEAR mt_rows.
    SELECT companycode, sapdocument, fiscalyear, creationdate, customername,
           totalvalue, currency, einvoicestatus, messagetype,
           einvoicetype ", documentcategory AS doccategory
      FROM zi_einvoice_header
      WHERE companycode     IN @s_bukrs
        AND companycode    IN @lr_land
        AND creationdate    IN @s_erdat
        AND einvoiceenabled EQ @abap_true
        AND businesstype    IN @lr_btype
        AND type            IN @lr_type
      ORDER BY companycode, sapdocument, fiscalyear
      INTO CORRESPONDING FIELDS OF TABLE @mt_rows.

    "Only company codes the user is allowed to display
    LOOP AT mt_rows INTO DATA(ls_row).
      INSERT ls_row-companycode INTO TABLE lt_bukrs.
    ENDLOOP.
    LOOP AT lt_bukrs INTO DATA(lv_bukrs).
      AUTHORITY-CHECK OBJECT 'F_BKPF_BUK'
        ID 'BUKRS' FIELD lv_bukrs
        ID 'ACTVT' FIELD '03'.
      IF sy-subrc <> 0.
        DELETE mt_rows WHERE companycode = lv_bukrs.
      ENDIF.
    ENDLOOP.
    "Separate corner statuses - same source as ZEI_UAE_INV_COCKPIT
    IF mt_rows IS NOT INITIAL.
      SELECT bukrs, vbeln, gjahr,
             zzc1_status, zzc2_status, zzc3_sent_status, zzc3_ack_status,
             zzc4_status, zzc5_rep_status, zzc5_ack_status,
             zzoverall_status
        FROM zeinvoice_detail
        FOR ALL ENTRIES IN @mt_rows
        WHERE bukrs EQ @mt_rows-companycode AND
              vbeln EQ @mt_rows-sapdocument AND
              gjahr EQ @mt_rows-fiscalyear
        INTO TABLE @DATA(lt_det).
      SORT lt_det BY bukrs vbeln gjahr.
      LOOP AT mt_rows ASSIGNING FIELD-SYMBOL(<ls_det_row>).
        READ TABLE lt_det INTO DATA(ls_det)
             WITH KEY bukrs = <ls_det_row>-companycode
                      vbeln = <ls_det_row>-sapdocument
                      gjahr = <ls_det_row>-fiscalyear BINARY SEARCH.
        IF sy-subrc EQ 0.
          <ls_det_row>-zzc1_status      = ls_det-zzc1_status.
          <ls_det_row>-zzc2_status      = ls_det-zzc2_status.
          <ls_det_row>-zzc3_sent_status = ls_det-zzc3_sent_status.
          <ls_det_row>-zzc3_ack_status  = ls_det-zzc3_ack_status.
          <ls_det_row>-zzc4_status      = ls_det-zzc4_status.
          <ls_det_row>-zzc5_rep_status  = ls_det-zzc5_rep_status.
          <ls_det_row>-zzc5_ack_status  = ls_det-zzc5_ack_status.
          <ls_det_row>-zzoverall_status = ls_det-zzoverall_status.
        ENDIF.
      ENDLOOP.
    ENDIF.


    mv_time = |{ sy-datum DATE = USER } { sy-uzeit TIME = USER }|.
  ENDMETHOD.

  METHOD classify.

    "Status model of ZEI_UAE_INV_COCKPIT: one status per corner
    "(ZEINVOICE_DETAIL-ZZ*) and the overall status SUCCESS / FAILED /
    "IN PROGRESS - SUCCESS only when Accepted by FTA (Corner 5)
    CONSTANTS: lc_gen     TYPE c LENGTH 1  VALUE 'G',   "C1 Generated in SAP
               lc_acc     TYPE c LENGTH 1  VALUE 'A',   "C2 Accepted by Supplier's ASP
               lc_rej     TYPE c LENGTH 1  VALUE 'R',   "C2 Rejected by Supplier's ASP
               lc_ok      TYPE c LENGTH 1  VALUE 'S',
               lc_fail    TYPE c LENGTH 1  VALUE 'F',
               lc_success TYPE c LENGTH 12 VALUE 'SUCCESS',
               lc_failed  TYPE c LENGTH 12 VALUE 'FAILED',
               lc_inproc  TYPE c LENGTH 12 VALUE 'IN PROGRESS'.

    mt_buckets = VALUE #(
      ( id = gc_b-completed label = `Accepted by FTA` color = `#188918`
        descr = `Completed - all 5 corners done, accepted by the FTA` )
      ( id = gc_b-inprocess label = `In Process` color = `#0070F2`
        descr = `Accepted by Supplier's ASP, waiting for Buyer's ASP / FTA` )
      ( id = gc_b-notsent   label = `Not Yet Submitted` color = `#C87B00`
        descr = `Not yet accepted by Supplier's ASP (pending or technical error - retry)` )
      ( id = gc_b-failed    label = `Failed` color = `#E76500`
        descr = `Failed at Buyer's ASP or FTA after acceptance (Corner 3 - 5)` )
      ( id = gc_b-rejected  label = `Rejected` color = `#D20A0A`
        descr = `Rejected by Supplier's ASP (validation error)` )
      ( id = gc_b-duplicate label = `Duplicate` color = `#6A6D70`
        descr = `Document already exists at the ASP (old status)` ) ).

    mt_corner = VALUE #( ( 0 ) ( 0 ) ( 0 ) ( 0 ) ( 0 ) ).

    LOOP AT mt_rows ASSIGNING FIELD-SYMBOL(<ls_row>).
      DATA(lv_st) = to_upper( CONV string( <ls_row>-einvoicestatus ) ).

      "Document type: UNTDID 1001 code 381 / SD category O = credit note
      <ls_row>-doctypetext = COND #( WHEN <ls_row>-einvoicetype = '381' THEN 'Credit Note'
                                     WHEN <ls_row>-einvoicetype = '380' THEN 'Invoice'
                                     "WHEN <ls_row>-doccategory = 'O' THEN 'Credit Note'
                                     ELSE 'Invoice' ).

      "Documents processed before the separate corner fields existed:
      "same start values as the cockpit (taken from the old single status)
      IF <ls_row>-zzc1_status IS INITIAL AND <ls_row>-zzc2_status IS INITIAL.
        DATA(lv_fail) = 0.
        DATA(lv_lvl)  = 0.
        IF lv_st CP 'FAILED_C*' OR lv_st CP 'REJECTED_C*' OR lv_st CP 'EXISTS_C*'.
          lv_fail = substring( val = lv_st off = strlen( lv_st ) - 1 len = 1 ).
          lv_lvl  = lv_fail - 1.
        ELSE.
          lv_lvl = COND #( WHEN lv_st CP 'C5*' THEN 5
                           WHEN lv_st CP 'C4*' THEN 4
                           WHEN lv_st CP 'C3*' OR lv_st EQ 'SUCCESS' THEN 3
                           WHEN lv_st CP 'C2*' THEN 2
                           WHEN lv_st CP 'C1*' THEN 1
                           ELSE 0 ).
        ENDIF.
        IF lv_st EQ 'REJECTED_C2'.
          <ls_row>-zzc1_status = lc_gen.
          <ls_row>-zzc2_status = lc_rej.
        ELSEIF lv_fail GE 3 OR ( lv_fail EQ 0 AND lv_lvl GE 2 ).
          <ls_row>-zzc1_status = lc_gen.
          <ls_row>-zzc2_status = lc_acc.
        ELSEIF lv_fail EQ 0 AND lv_lvl EQ 1.
          <ls_row>-zzc1_status = lc_gen.
        ENDIF.
      ENDIF.

      "Overall status - same rule as the cockpit
      DATA(lv_any_failed) = xsdbool( <ls_row>-zzc3_sent_status EQ lc_fail OR
                                     <ls_row>-zzc3_ack_status  EQ lc_fail OR
                                     <ls_row>-zzc4_status      EQ lc_fail OR
                                     <ls_row>-zzc5_rep_status  EQ lc_fail OR
                                     <ls_row>-zzc5_ack_status  EQ lc_fail ).
      <ls_row>-zzoverall_status = COND #(
        WHEN <ls_row>-zzc2_status EQ lc_rej OR lv_any_failed EQ abap_true THEN lc_failed
        WHEN <ls_row>-zzc5_ack_status EQ lc_ok                          THEN lc_success
        WHEN <ls_row>-zzc1_status IS NOT INITIAL                        THEN lc_inproc
        ELSE space ).

      "Dashboard bucket
      <ls_row>-bucket = COND i(
        WHEN <ls_row>-zzoverall_status EQ lc_success THEN gc_b-completed
        WHEN <ls_row>-zzc2_status      EQ lc_rej     THEN gc_b-rejected
        WHEN <ls_row>-zzoverall_status EQ lc_failed  THEN gc_b-failed
        WHEN <ls_row>-zzc2_status      EQ lc_acc     THEN gc_b-inprocess
        WHEN lv_st CP 'EXISTS*'                      THEN gc_b-duplicate
        ELSE gc_b-notsent ).

      READ TABLE mt_buckets ASSIGNING FIELD-SYMBOL(<ls_b>) WITH KEY id = <ls_row>-bucket.
      IF sy-subrc = 0.
        <ls_b>-count = <ls_b>-count + 1.
        <ls_row>-statustext = <ls_b>-label.
      ENDIF.

      "Latest corner status - same text as the cockpit (E-Invoice Status)
      <ls_row>-cornertext = COND string(
        WHEN <ls_row>-zzc2_status      EQ lc_rej  THEN `Rejected by Supplier's ASP`
        WHEN <ls_row>-zzc3_sent_status EQ lc_fail THEN `Sent to Buyer's ASP`
        WHEN <ls_row>-zzc3_ack_status  EQ lc_fail THEN `Accepted by Buyer's ASP`
        WHEN <ls_row>-zzc4_status      EQ lc_fail THEN `Delivered to Buyer`
        WHEN <ls_row>-zzc5_rep_status  EQ lc_fail THEN `Reported to FTA`
        WHEN <ls_row>-zzc5_ack_status  EQ lc_fail THEN `Accepted by FTA`
        WHEN <ls_row>-zzc5_ack_status  EQ lc_ok   THEN `Accepted by FTA`
        WHEN <ls_row>-zzc5_rep_status  EQ lc_ok   THEN `Reported to FTA`
        WHEN <ls_row>-zzc4_status      EQ lc_ok   THEN `Delivered to Buyer`
        WHEN <ls_row>-zzc3_ack_status  EQ lc_ok   THEN `Accepted by Buyer's ASP`
        WHEN <ls_row>-zzc3_sent_status EQ lc_ok   THEN `Sent to Buyer's ASP`
        WHEN <ls_row>-zzc2_status      EQ lc_acc  THEN `Accepted by Supplier's ASP`
        WHEN <ls_row>-zzc1_status      EQ lc_gen  THEN `Generated in SAP`
        ELSE `Not yet submitted` ).

      "E-invoice journey: furthest corner completed (C3 = sent + accepted,
      "C5 = reported + accepted - same as the 5 corner boxes of the cockpit)
      DATA(lv_cur) = COND i(
        WHEN <ls_row>-zzc5_rep_status EQ lc_ok AND <ls_row>-zzc5_ack_status EQ lc_ok THEN 5
        WHEN <ls_row>-zzc4_status EQ lc_ok                                           THEN 4
        WHEN <ls_row>-zzc3_sent_status EQ lc_ok AND <ls_row>-zzc3_ack_status EQ lc_ok THEN 3
        WHEN <ls_row>-zzc2_status EQ lc_acc                                          THEN 2
        WHEN <ls_row>-zzc1_status EQ lc_gen                                          THEN 1
        ELSE 0 ).
      IF lv_cur GT 0.
        mt_corner[ lv_cur ] = mt_corner[ lv_cur ] + 1.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.

  METHOD add.
    mv_html = mv_html && iv.
  ENDMETHOD.

  METHOD pct.
    DATA lv_p TYPE p LENGTH 8 DECIMALS 1.
    IF iv_total = 0.
      rv = `0.0`.
    ELSE.
      lv_p = CONV decfloat34( iv_part ) * 100 / iv_total.
      rv = |{ lv_p }|.
    ENDIF.
  ENDMETHOD.

  METHOD esc.
    rv = escape( val = iv format = cl_abap_format=>e_xss_ml ).
  ENDMETHOD.

  METHOD filter_text.
    "HTML filter bar (submits SAPEVENT:FILTER?cc=..&df=..&dt=..&bt=..&ty=..)
    DATA: lv_cc TYPE string,
          lv_df TYPE string,
          lv_dt TYPE string.

    LOOP AT s_bukrs INTO DATA(ls_cc).
      IF lv_cc IS NOT INITIAL.
        lv_cc = lv_cc && `, `.
      ENDIF.
      lv_cc = lv_cc && ls_cc-low.
      IF ls_cc-high IS NOT INITIAL.
        lv_cc = lv_cc && `-` && ls_cc-high.
      ENDIF.
    ENDLOOP.

    READ TABLE s_erdat INDEX 1 INTO DATA(ls_dt).
    IF sy-subrc = 0.
      IF ls_dt-option = 'LE'.
        lv_dt = iso( ls_dt-low ).
      ELSE.
        lv_df = iso( ls_dt-low ).
        lv_dt = iso( ls_dt-high ).
      ENDIF.
    ENDIF.

    rv = `<form class="flt" method="get" action="SAPEVENT:FILTER">`
      && `<label>Country<select name="ld">` && options_html( it_opt = mt_opt_ld iv_sel = p_land ) && `</select></label>`
      && `<label>Company Code<select name="cc">` && options_html( it_opt = mt_opt_cc iv_sel = lv_cc ) && `</select></label>`
      && `<label>Creation Date From<input type="date" name="df" value="` && lv_df && `"></label>`
      && `<label>To<input type="date" name="dt" value="` && lv_dt && `"></label>`
      && `<label>Business Type<select name="bt">` && options_html( it_opt = mt_opt_bt iv_sel = p_btype ) && `</select></label>`
      && `<label>E-Invoice Type<select name="ty">` && options_html( it_opt = mt_opt_ty iv_sel = p_type ) && `</select></label>`
      && `<button type="submit" class="go">Go</button><a class="clr" href="SAPEVENT:RESET">Reset</a>`
      && `<span class="rf"><span class="sub">Last refreshed: ` && mv_time && `</span>`
      && `<a class="btn" href="sapevent:REFRESH">&#8635; Refresh</a></span></form>`.
  ENDMETHOD.

  METHOD tile.
    add( `<a class="tile" href="SAPEVENT:` && iv_action && `">` ).
    add( `<div class="tl">` && iv_label && `</div>` ).
    add( `<div class="tv" style="color:` && iv_color && `">` && iv_value && `</div>` ).
    add( `<div class="ts">` && iv_sub && `</div></a>` ).
  ENDMETHOD.

  METHOD build_html.
    DATA: lv_cum  TYPE p LENGTH 8 DECIMALS 2,
          lv_seg  TYPE p LENGTH 8 DECIMALS 2,
          lv_rest TYPE p LENGTH 8 DECIMALS 2,
          lv_off  TYPE p LENGTH 8 DECIMALS 2.

    DATA(lv_total) = lines( mt_rows ).
    DATA(lv_done)  = mt_buckets[ id = gc_b-completed ]-count.
    DATA(lv_proc)  = mt_buckets[ id = gc_b-inprocess ]-count.
    DATA(lv_nsent) = mt_buckets[ id = gc_b-notsent ]-count.
    DATA(lv_err)   = mt_buckets[ id = gc_b-failed ]-count
                   + mt_buckets[ id = gc_b-rejected ]-count
                   + mt_buckets[ id = gc_b-duplicate ]-count.
    DATA(lv_todo)  = lv_nsent + lv_err.

    CLEAR mv_html.
    "----- Styles (SAP Horizon look) -----
    add( `<!DOCTYPE html><html><head><meta charset="utf-8">` ).
    add( `<meta http-equiv="X-UA-Compatible" content="IE=edge"><style>` ).
    add( `body{margin:0;font-family:'72','Segoe UI',Arial,sans-serif;background:#f5f6f7;color:#1d2d3e;font-size:13px}` ).
    add( `a{color:inherit;text-decoration:none}` ).
    add( `.hdr{background:#fff;padding:14px 20px;border-bottom:1px solid #e5e5e5;display:flex;justify-content:space-between;align-items:center}.hdr>div:last-child{white-space:nowrap;margin-left:16px}` ).
    add( `h1{margin:0;font-size:22px;font-weight:700}.sub{color:#556b82;margin-top:4px;font-size:12px}` ).
    add( `.btn{border:1px solid #0064d9;color:#0064d9;background:#fff;border-radius:8px;padding:6px 14px;font-weight:600}.btn:hover{background:#ebf8ff}` ).
    add( `.flt{display:flex;flex-wrap:wrap;align-items:flex-end;margin:0;padding:6px 20px 6px;background:#fff;border-bottom:1px solid #e5e5e5}` ).
    add( `.flt label{display:flex;flex-direction:column;font-size:11px;line-height:13px;color:#556b82;margin:0 10px 0 0}` ).
    add( `.flt input,.flt select{height:26px;box-sizing:border-box;border:1px solid #bcc3ca;border-radius:6px;padding:0 6px;font-size:12px;color:#1d2d3e;background:#fff;margin-top:2px;min-width:100px;max-width:160px}` ).
    add( `.flt input:focus,.flt select:focus{outline:none;border-color:#0064d9;box-shadow:0 0 0 1px #0064d9}` ).
    add( `.go{height:26px;margin:0 12px 0 0;padding:0 18px;border:0;border-radius:8px;background:#0064d9;color:#fff;font-weight:600;font-size:13px;cursor:pointer}.go:hover{background:#0050b0}` ).
    add( `.clr{color:#0064d9;font-weight:600;font-size:12px;margin-bottom:5px;white-space:nowrap}` ).
    add( `.rf{margin-left:auto;display:flex;align-items:center;gap:12px;white-space:nowrap}.rf .sub{margin:0}.flt .btn{padding:4px 12px;font-size:12px;text-decoration:none}` ).
    add( `form.flt{flex:1 1 auto}.rf{padding-left:16px}` ).
    add( `.wrap{padding:8px 12px}.row{display:flex;flex-wrap:wrap}` ).
    add( `.tile,.card{background:#fff;border-radius:12px;box-shadow:0 0 2px rgba(34,53,72,.2),0 2px 4px rgba(34,53,72,.1);margin:8px}` ).
    add( `.tile{flex:1 1 0;min-width:100px;padding:14px;display:block}.tile:hover{box-shadow:0 0 2px rgba(34,53,72,.25),0 8px 16px rgba(34,53,72,.18)}` ).
    add( `.tl{font-size:14px}.tv{font-size:36px;font-weight:300;margin:8px 0 4px}.ts{font-size:12px;color:#556b82}` ).
    add( `.card{flex:1 1 440px;padding:20px}.card h2{margin:0;font-size:18px}` ).
    add( `.donut{display:flex;align-items:center;flex-wrap:wrap;margin-top:12px}` ).
    add( `table.lg{border-collapse:collapse;flex:1;min-width:320px;margin-left:16px}table.lg td{padding:7px 6px;border-bottom:1px solid #eef0f2}` ).
    add( `table.lg tr:hover{background:#f5f9ff}table.lg a{font-weight:600}` ).
    add( `.dot{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:8px;vertical-align:middle}` ).
    add( `.ds{font-size:11px;color:#6a6d70;margin:2px 0 0 20px}.num{text-align:right;font-weight:700}.pc{text-align:right;color:#556b82;width:52px}` ).
    add( `.bar{background:#eef0f2;border-radius:4px;height:6px;width:90px}.bar div{height:6px;border-radius:4px}` ).
    add( `.pipe{display:flex;margin-top:26px}.step{flex:1;text-align:center;position:relative}` ).
    add( `.line{position:absolute;top:23px;left:50%;width:100%;height:3px;background:#d1e8ff}` ).
    add( `.circ{position:relative;width:46px;height:46px;line-height:46px;border-radius:50%;margin:0 auto;background:#e8f2ff;color:#0064d9;font-weight:700;font-size:16px;border:2px solid #fff}` ).
    add( `.c5{background:#e5f5e5;color:#188918}.lbl{font-size:12px;margin-top:8px;color:#556b82}.lbl b{color:#1d2d3e}` ).
    add( `.hint{color:#556b82;font-size:12px;margin-top:28px;border-top:1px solid #eef0f2;padding-top:14px}.hint li{margin:4px 0}` ).
    add( `.empty{text-align:center;color:#556b82;padding:20px;font-size:14px}` ).
    add( `.tbl{flex:1 1 100%;padding:16px 20px}.lh{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;margin-bottom:10px}` ).
    add( `.srch{height:32px;box-sizing:border-box;border:1px solid #bcc3ca;border-radius:16px;padding:0 14px;min-width:220px;font-size:13px}.chip{color:#0064d9;font-weight:600;margin-left:10px}` ).
    add( `.tw{overflow-x:auto}table.dl{width:100%;border-collapse:collapse}table.dl td{padding:8px;border-bottom:1px solid #eef0f2;white-space:nowrap}` ).
    add( `table.dl th{text-align:left;font-weight:600;color:#556b82;font-size:12px;padding:8px;border-bottom:2px solid #e5e5e5;cursor:pointer;white-space:nowrap;user-select:none}` ).
    add( `table.dl th:hover{color:#0064d9}table.dl tbody tr:hover td{background:#f5f9ff}.r{text-align:right}.doc{color:#0064d9;font-weight:600}` ).
    add( `.bdg{display:inline-block;padding:2px 10px;border-radius:10px;font-size:12px;font-weight:600}.ei{color:#6a6d70;font-size:12px}` ).
    add( `.dt{display:inline-block;padding:1px 8px;border-radius:4px;font-size:11px;font-weight:600;color:#0064d9;background:#ebf8ff;border:1px solid #bcd9f5}.dt.cn{color:#a93e00;background:#fff3e6;border-color:#f5c99a}` ).
    add( `</style></head><body>` ).

    "----- Header -----
    add( `<div class="flt">` && filter_text( ) && `</div>` ).

    "----- KPI tiles -----
    add( `<div class="wrap"><div class="row">` ).
    tile( iv_action = `ALL` iv_label = `Total E-Invoices` iv_value = |{ lv_total }|
          iv_sub = `All E-Invoice relevant documents` iv_color = `#1d2d3e` ).
    tile( iv_action = `B1` iv_label = `Accepted by FTA` iv_value = |{ lv_done }|
          iv_sub = pct( iv_part = lv_done iv_total = lv_total ) && `% of total - fully completed` iv_color = `#188918` ).
    tile( iv_action = `B2` iv_label = `In Process` iv_value = |{ lv_proc }|
          iv_sub = `Accepted by Supplier's ASP, awaiting Buyer's ASP / FTA` iv_color = `#0070F2` ).
    tile( iv_action = `ACTION` iv_label = `Needs Action` iv_value = |{ lv_todo }|
          iv_sub = `Not submitted, failed, rejected or duplicate` iv_color = `#E76500` ).
    tile( iv_action = `ERROR` iv_label = `Error Rate` iv_value = pct( iv_part = lv_err iv_total = lv_total ) && `%`
          iv_sub = |{ lv_err } of { lv_total } failed, rejected or duplicate| iv_color = `#D20A0A` ).
    add( `</div><div class="row">` ).

    "----- Status breakdown (donut + legend) -----
    add( `<div class="card"><h2>Status Breakdown</h2>` ).
    add( `<div class="donut"><svg width="210" height="210" viewBox="0 0 42 42">` ).
    add( `<circle cx="21" cy="21" r="15.9155" fill="none" stroke="#eef0f2" stroke-width="5"></circle>` ).
    IF lv_total > 0.
      LOOP AT mt_buckets INTO DATA(ls_b) WHERE count > 0.
        lv_seg  = CONV decfloat34( ls_b-count ) * 100 / lv_total.
        lv_rest = 100 - lv_seg.
        lv_off  = 25 - lv_cum.
        IF lv_off < 0.
          lv_off = lv_off + 100.
        ENDIF.
        add( `<circle cx="21" cy="21" r="15.9155" fill="none" stroke-width="5" stroke="` && ls_b-color
          && `" stroke-dasharray="` && |{ lv_seg } { lv_rest }| && `" stroke-dashoffset="` && |{ lv_off }|
          && `"><title>` && ls_b-label && `: ` && |{ ls_b-count }| && `</title></circle>` ).
        lv_cum = lv_cum + lv_seg.
      ENDLOOP.
    ENDIF.
    add( `<text x="21" y="18.5" text-anchor="middle" font-size="2.6" fill="#556b82">TOTAL</text>` ).
    add( `<text x="21" y="24.2" text-anchor="middle" font-size="6" font-weight="bold" fill="#1d2d3e">` && |{ lv_total }| && `</text>` ).
    add( `<text x="21" y="27.8" text-anchor="middle" font-size="2.4" fill="#556b82">E-Invoices</text></svg>` ).

    add( `<table class="lg">` ).
    LOOP AT mt_buckets INTO ls_b.
      DATA(lv_p) = pct( iv_part = ls_b-count iv_total = lv_total ).
      add( `<tr><td><a href="SAPEVENT:B` && |{ ls_b-id }| && `"><span class="dot" style="background:` && ls_b-color && `"></span>`
        && ls_b-label && `</a><div class="ds">` && ls_b-descr && `</div></td>` ).
      add( `<td class="num">` && |{ ls_b-count }| && `</td><td class="pc">` && lv_p && `%</td>` ).
      add( `<td><div class="bar"><div style="width:` && lv_p && `%;background:` && ls_b-color && `"></div></div></td></tr>` ).
    ENDLOOP.
    add( `</table></div>` ).
    IF lv_total = 0.
      add( `<div class="empty">No E-Invoices found for the selected filters</div>` ).
    ENDIF.
    add( `</div>` ).

    "----- E-invoice journey (5 corners) -----
    add( `<div class="card"><h2>E-Invoice Journey</h2>` ).
    add( `<div class="pipe">` ).
    DATA(lt_steps) = VALUE string_table( ( `Generated in SAP` ) ( `Accepted by Supplier's ASP` ) ( `Sent to / Accepted by Buyer's ASP` )
                                         ( `Delivered to Buyer` ) ( `Reported to / Accepted by FTA` ) ).
    LOOP AT lt_steps INTO DATA(lv_step).
      DATA(lv_i) = sy-tabix.
      add( `<div class="step">` ).
      IF lv_i < 5.
        add( `<div class="line"></div>` ).
      ENDIF.
      add( `<div class="circ` && COND string( WHEN lv_i = 5 THEN ` c5` ) && `">` && |{ mt_corner[ lv_i ] }|
        && `</div><div class="lbl"><b>Corner ` && |{ lv_i }| && `</b><br>` && lv_step && `</div></div>` ).
    ENDLOOP.
    add( `</div>` ).
    add( `<div class="hint"><b style="color:#1d2d3e">How to read this dashboard</b><ul style="margin:6px 0 0 18px;padding:0">` ).
    add( `<li><b style="color:#188918">Accepted by FTA</b> - all 5 corners done, no action needed.</li>` ).
    add( `<li><b style="color:#0070F2">In Process</b> - accepted by Supplier's ASP, waiting for Buyer's ASP / FTA acknowledgement.</li>` ).
    add( `<li><b style="color:#E76500">Needs Action</b> - not yet submitted, failed, rejected or duplicate. Fix in the E-Invoice Cockpit.</li>` ).
    add( `<li>Click a tile or status to filter the document list below; click a document number to open it.</li>` ).
    add( `</ul></div></div>` ).
    "----- Document list -----
    show_list( mv_filter ).
    add( `</div><div class="row"><div class="card tbl" id="list"><div class="lh"><div><h2>`
      && esc( mv_list_title ) && | ({ lines( mt_list ) })| && `</h2><div class="sub">` ).
    IF mv_filter <> 'ALL'.
      add( `<a class="chip" href="SAPEVENT:ALL">&#10005; Show all</a>` ).
    ENDIF.
    add( `</div></div><input id="q" class="srch" placeholder="Search documents..." onkeyup="flt()"></div>` ).
    add( `<div class="tw"><table class="dl" id="dl"><thead><tr><th onclick="srt(0)">Document</th><th onclick="srt(1)">Type</th><th onclick="srt(2)">Year</th>` ).
    add( `<th onclick="srt(3)">Co. Code</th><th onclick="srt(4)">Created On</th><th onclick="srt(5)">Customer</th>` ).
    add( `<th class="r" onclick="srt(6)">Amount</th><th onclick="srt(7)">Curr.</th><th onclick="srt(8)">Status</th><th onclick="srt(9)">E-Invoice Status</th></tr></thead><tbody>` ).
    LOOP AT mt_list INTO DATA(ls_l).
      DATA(lv_col) = VALUE #( mt_buckets[ id = ls_l-bucket ]-color OPTIONAL ).
      add( `<tr><td><a class="doc" href="SAPEVENT:DOC_` && ls_l-sapdocument && `">` && |{ ls_l-sapdocument ALPHA = OUT }| && `</a></td>` ).
      add( `<td><span class="dt` && COND string( WHEN ls_l-doctypetext = 'Credit Note' THEN ` cn` ) && `">` && esc( ls_l-doctypetext ) && `</span></td>` ).
      add( `<td>` && ls_l-fiscalyear && `</td><td>` && ls_l-companycode && `</td>` ).
      add( `<td data-v="` && ls_l-creationdate && `">` && |{ ls_l-creationdate DATE = USER }| && `</td><td>` && esc( ls_l-customername ) && `</td>` ).
      add( `<td class="r" data-v="` && |{ ls_l-totalvalue }| && `">` && |{ ls_l-totalvalue NUMBER = USER }| && `</td><td>` && ls_l-currency && `</td>` ).
      add( `<td><span class="bdg" style="color:` && lv_col && `;background:` && lv_col && `1A">` && esc( ls_l-statustext ) && `</span></td>` ).
      add( `<td class="ei">` && esc( ls_l-cornertext ) && `</td></tr>` ).
    ENDLOOP.
    IF mt_list IS INITIAL.
      add( `<tr><td colspan="10" class="empty">No E-Invoices found for the selected filters</td></tr>` ).
    ENDIF.
    add( `</tbody></table></div></div>` ).

    "----- Client-side search and sort -----
    add( `<script>function flt(){var q=document.getElementById('q').value.toLowerCase(),r=document.getElementById('dl').tBodies[0].rows;` ).
    add( `for(var i=0;i<r.length;i++){r[i].style.display=(r[i].innerText||r[i].textContent).toLowerCase().indexOf(q)>-1?'':'none';}}` ).
    add( `function srt(c){var t=document.getElementById('dl').tBodies[0],r=[].slice.call(t.rows),d=(t.getAttribute('data-c')==String(c)&&t.getAttribute('data-d')=='1')?-1:1;` ).
    add( `t.setAttribute('data-c',c);t.setAttribute('data-d',d);r.sort(function(a,b){if(!a.cells[c]||!b.cells[c])return 0;` ).
    add( `var x=a.cells[c].getAttribute('data-v')||a.cells[c].innerText,y=b.cells[c].getAttribute('data-v')||b.cells[c].innerText;` ).
    add( `var nx=parseFloat(x),ny=parseFloat(y);if(!isNaN(nx)&&!isNaN(ny)&&/^-?[0-9.]+$/.test(x)&&/^-?[0-9.]+$/.test(y))return(nx-ny)*d;` ).
    add( `return x.localeCompare(y)*d;});for(var i=0;i<r.length;i++)t.appendChild(r[i]);}` ).
    IF mv_scroll = abap_true.
      add( `window.onload=function(){var e=document.getElementById('list');if(e)e.scrollIntoView();};` ).
      CLEAR mv_scroll.
    ENDIF.
    add( `</script>` ).
    add( `</div></div></body></html>` ).
  ENDMETHOD.

  METHOD show_html.
    DATA: lt_html TYPE tt_line,
          lv_url  TYPE c LENGTH 255.

    IF mo_html IS NOT BOUND.
      "Full-screen HTML control (no docking / splitter)
      CREATE OBJECT mo_html
        EXPORTING
          parent = cl_gui_container=>screen0
        EXCEPTIONS
          OTHERS = 1.
      IF sy-subrc <> 0.
        MESSAGE 'Dashboard control could not be created' TYPE 'S' DISPLAY LIKE 'E'.
        RETURN.
      ENDIF.
      DATA lt_events TYPE cntl_simple_events.
      APPEND VALUE cntl_simple_event( eventid = cl_gui_html_viewer=>m_id_sapevent appl_event = abap_false ) TO lt_events.
      mo_html->set_registered_events( EXPORTING events = lt_events EXCEPTIONS OTHERS = 1 ).
      SET HANDLER on_sapevent FOR mo_html.
    ENDIF.

    "Split HTML into 255-character lines
    DATA(lv_len) = strlen( mv_html ).
    DATA(lv_pos) = 0.
    WHILE lv_pos < lv_len.
      DATA(lv_n) = nmin( val1 = 255 val2 = lv_len - lv_pos ).
      APPEND substring( val = mv_html off = lv_pos len = lv_n ) TO lt_html.
      lv_pos = lv_pos + lv_n.
    ENDWHILE.

    mo_html->load_data( EXPORTING  size         = lv_len
                        IMPORTING  assigned_url = lv_url
                        CHANGING   data_table   = lt_html
                        EXCEPTIONS OTHERS       = 1 ).
    mo_html->show_url( EXPORTING url = lv_url EXCEPTIONS OTHERS = 1 ).
  ENDMETHOD.

  METHOD on_sapevent.
    DATA: lt_kv   TYPE tt_kv,
          lv_full TYPE string,
          lv_act  TYPE string,
          lv_q    TYPE string,
          lv_n    TYPE string,
          lv_v    TYPE string.

    lv_full = action.
    SPLIT lv_full AT '?' INTO lv_act lv_q.
    mv_action = to_upper( condense( lv_act ) ).

    "Form fields - SAP GUI passes them in QUERY_TABLE, WebGUI in the URL
    LOOP AT query_table INTO DATA(ls_q).
      APPEND VALUE #( name = to_lower( condense( CONV string( ls_q-name ) ) )
                      value = condense( CONV string( ls_q-value ) ) ) TO lt_kv.
    ENDLOOP.
    IF lt_kv IS INITIAL.
      IF lv_q IS INITIAL.
        lv_q = getdata.
      ENDIF.
      SPLIT lv_q AT '&' INTO TABLE DATA(lt_parts).
      LOOP AT lt_parts INTO DATA(lv_part).
        SPLIT lv_part AT '=' INTO lv_n lv_v.
        REPLACE ALL OCCURRENCES OF '+' IN lv_v WITH ` `.
        APPEND VALUE #( name  = to_lower( condense( lv_n ) )
                        value = condense( cl_http_utility=>unescape_url( lv_v ) ) ) TO lt_kv.
      ENDLOOP.
    ENDIF.

    CASE mv_action.
      WHEN 'FILTER'.
        apply_filters( lt_kv ).
      WHEN 'RESET'.
        mv_filter = 'ALL'.
        CLEAR: s_bukrs[], p_btype, p_type, p_land.
        s_erdat[] = VALUE #( ( sign = 'I' option = 'BT' low = CONV d( sy-datum - 30 ) high = sy-datum ) ).
    ENDCASE.

    cl_gui_cfw=>set_new_ok_code( 'ZEIDRILL' ).
  ENDMETHOD.

  METHOD apply_filters.
    DATA: ls_cc LIKE LINE OF s_bukrs,
          ls_dt LIKE LINE OF s_erdat,
          lv_cc TYPE string.

    CLEAR: s_bukrs[], s_erdat[], p_btype, p_type, p_land.

    LOOP AT it_kv INTO DATA(ls_kv).
      CASE ls_kv-name.
        WHEN 'cc'.                     "e.g. 3310, 3320 or 3300-3399
          lv_cc = to_upper( ls_kv-value ).
          REPLACE ALL OCCURRENCES OF PCRE '[,;]' IN lv_cc WITH ` `.
          lv_cc = condense( lv_cc ).
          SPLIT lv_cc AT space INTO TABLE DATA(lt_cc).
          LOOP AT lt_cc INTO DATA(lv_tok) WHERE table_line IS NOT INITIAL.
            CLEAR ls_cc.
            ls_cc-sign = 'I'.
            IF lv_tok CS '-'.
              SPLIT lv_tok AT '-' INTO DATA(lv_lo) DATA(lv_hi).
              ls_cc-option = 'BT'.
              ls_cc-low    = lv_lo.
              ls_cc-high   = lv_hi.
            ELSE.
              ls_cc-option = 'EQ'.
              ls_cc-low    = lv_tok.
            ENDIF.
            APPEND ls_cc TO s_bukrs.
          ENDLOOP.
        WHEN 'df'.
          ls_dt-low = to_date( ls_kv-value ).
        WHEN 'dt'.
          ls_dt-high = to_date( ls_kv-value ).
        WHEN 'bt'.
          p_btype = ls_kv-value.
        WHEN 'ty'.
          p_type = ls_kv-value.
        WHEN 'ld'.
          p_land = ls_kv-value.
      ENDCASE.
    ENDLOOP.

    IF ls_dt-low IS NOT INITIAL OR ls_dt-high IS NOT INITIAL.
      ls_dt-sign = 'I'.
      IF ls_dt-high IS INITIAL.
        ls_dt-option = 'GE'.
      ELSEIF ls_dt-low IS INITIAL.
        ls_dt-option = 'LE'.
        ls_dt-low    = ls_dt-high.
        CLEAR ls_dt-high.
      ELSE.
        ls_dt-option = 'BT'.
        IF ls_dt-low > ls_dt-high.
          DATA(lv_swap) = ls_dt-low.
          ls_dt-low  = ls_dt-high.
          ls_dt-high = lv_swap.
        ENDIF.
      ENDIF.
      APPEND ls_dt TO s_erdat.
    ENDIF.
  ENDMETHOD.

  METHOD to_date.
    DATA(lv) = condense( iv ).
    IF lv CP '++++-++-++'.             "yyyy-mm-dd (HTML date input)
      rv = lv(4) && lv+5(2) && lv+8(2).
    ELSEIF lv CP '++.++.++++'.         "dd.mm.yyyy
      rv = lv+6(4) && lv+3(2) && lv(2).
    ENDIF.
  ENDMETHOD.

  METHOD iso.
    IF iv IS NOT INITIAL.
      rv = |{ iv DATE = ISO }|.
    ENDIF.
  ENDMETHOD.

  METHOD load_options.
    DATA: lo_el  TYPE REF TO cl_abap_elemdescr,
          lt_fix TYPE ddfixvalues,
          lt_bt  TYPE STANDARD TABLE OF knb1-zzbusinesstype WITH EMPTY KEY,
          lt_ty  TYPE STANDARD TABLE OF zde_ei_type WITH EMPTY KEY.

    "Country: distinct countries maintained in ZEINV_COMPANY
    SELECT DISTINCT land1, landx50 FROM zeinv_company
      WHERE land1 <> @space
      ORDER BY land1
      INTO TABLE @DATA(lt_ld).
    mt_opt_ld = VALUE #( FOR d IN lt_ld
                         ( value = d-land1
                           text  = COND string( WHEN d-landx50 IS INITIAL THEN CONV string( d-land1 )
                                                ELSE |{ d-land1 } - { d-landx50 }| ) ) ).

    "Company code: list maintained in ZEINV_COMPANY
    SELECT bukrs, butxt FROM zeinv_company
      ORDER BY bukrs
      INTO TABLE @DATA(lt_co).
    mt_opt_cc = VALUE #( FOR c IN lt_co
                         ( value = c-bukrs
                           text  = COND string( WHEN c-butxt IS INITIAL THEN CONV string( c-bukrs )
                                                ELSE |{ c-bukrs } - { c-butxt }| ) ) ).

    "Business type: domain fixed values, else values found in the data
    lo_el ?= cl_abap_typedescr=>describe_by_data( p_btype ).
    lo_el->get_ddic_fixed_values( EXPORTING  p_langu        = sy-langu
                                  RECEIVING  p_fixed_values = lt_fix
                                  EXCEPTIONS OTHERS         = 1 ).
    IF sy-subrc = 0.
      mt_opt_bt = VALUE #( FOR f IN lt_fix WHERE ( option = 'EQ' )
                  ( value = f-low text = COND string( WHEN f-ddtext IS INITIAL THEN f-low ELSE f-ddtext ) ) ).
    ENDIF.
    IF mt_opt_bt IS INITIAL.
      SELECT DISTINCT businesstype FROM zi_einvoice_header
        WHERE businesstype <> @space
        INTO TABLE @lt_bt.
      mt_opt_bt = VALUE #( FOR b IN lt_bt ( value = b text = b ) ).
    ENDIF.

    "E-invoice type
    CLEAR lt_fix.
    lo_el ?= cl_abap_typedescr=>describe_by_data( p_type ).
    lo_el->get_ddic_fixed_values( EXPORTING  p_langu        = sy-langu
                                  RECEIVING  p_fixed_values = lt_fix
                                  EXCEPTIONS OTHERS         = 1 ).
    IF sy-subrc = 0.
      mt_opt_ty = VALUE #( FOR f IN lt_fix WHERE ( option = 'EQ' )
                  ( value = f-low text = COND string( WHEN f-ddtext IS INITIAL THEN f-low ELSE f-ddtext ) ) ).
    ENDIF.
    IF mt_opt_ty IS INITIAL.
      SELECT DISTINCT type FROM zi_einvoice_header
        WHERE type <> @space
        INTO TABLE @lt_ty.
      mt_opt_ty = VALUE #( FOR t IN lt_ty ( value = t text = t ) ).
    ENDIF.
  ENDMETHOD.

  METHOD options_html.
    rv = `<option value="">All</option>`.
    LOOP AT it_opt INTO DATA(ls_o).
      rv = rv && `<option value="` && esc( ls_o-value ) && `"`
         && COND string( WHEN ls_o-value = iv_sel THEN ` selected` )
         && `>` && esc( ls_o-text ) && `</option>`.
    ENDLOOP.
  ENDMETHOD.

  METHOD handle_action.
    CASE iv_action.
      WHEN 'REFRESH' OR 'FILTER' OR 'RESET'.
        run( ).
        MESSAGE 'Dashboard refreshed' TYPE 'S'.
      WHEN OTHERS.
        IF iv_action CP 'DOC_*'.         "Document link: SAPEVENT:DOC_<billing doc>
          DATA(lv_vbeln) = CONV vbrk-vbeln( substring( val = iv_action off = 4 ) ).
          IF lv_vbeln IS NOT INITIAL.
            SET PARAMETER ID 'VF' FIELD lv_vbeln.
            TRY.
                CALL TRANSACTION 'VF03' WITH AUTHORITY-CHECK AND SKIP FIRST SCREEN.
              CATCH cx_sy_authorization_error.
                MESSAGE 'No authorization for transaction VF03' TYPE 'S' DISPLAY LIKE 'E'.
            ENDTRY.
            "WebGUI does not repaint the control after CALL TRANSACTION - recreate it
            free( ).
            mv_scroll = abap_true.
            build_html( ).
            show_html( ).
          ENDIF.
        ELSE.                          "Tile / status click: filter the list
          mv_filter = iv_action.
          mv_scroll = abap_true.
          build_html( ).
          show_html( ).
        ENDIF.
    ENDCASE.
  ENDMETHOD.

  METHOD show_list.
    DATA lv_title TYPE string.

    CLEAR mt_list.
    CASE iv_filter.
      WHEN 'ALL'.
        mt_list = mt_rows.
        lv_title = `All E-Invoices`.
      WHEN 'ACTION'.
        mt_list = VALUE #( FOR r IN mt_rows WHERE ( bucket >= gc_b-notsent ) ( r ) ).
        lv_title = `E-invoices that need action`.
      WHEN 'ERROR'.
        mt_list = VALUE #( FOR r IN mt_rows WHERE ( bucket >= gc_b-failed ) ( r ) ).
        lv_title = `Failed, rejected or duplicate E-Invoices`.
      WHEN OTHERS.
        IF strlen( iv_filter ) >= 2 AND iv_filter(1) = 'B'.
          DATA(lv_b) = CONV i( substring( val = iv_filter off = 1 ) ).
          mt_list = VALUE #( FOR r IN mt_rows WHERE ( bucket = lv_b ) ( r ) ).
          lv_title = VALUE #( mt_buckets[ id = lv_b ]-label OPTIONAL ).
          lv_title = `E-invoices: ` && lv_title.
        ELSE.
          mt_list = mt_rows.
          lv_title = `All E-Invoices`.
        ENDIF.
    ENDCASE.

    mv_list_title = lv_title.
  ENDMETHOD.

ENDCLASS.

DATA: go_dash   TYPE REF TO lcl_dash,
      gv_reload TYPE abap_bool.

*----------------------------------------------------------------------*
INITIALIZATION.
  s_erdat[] = VALUE #( ( sign = 'I' option = 'BT' low = CONV d( sy-datum - 30 ) high = sy-datum ) ).

*----------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  "Dashboard runs on the selection screen - hide Execute / Print / Background / Variant
  DATA lt_excl TYPE STANDARD TABLE OF sy-ucomm WITH EMPTY KEY.
  lt_excl = VALUE #( ( 'ONLI' ) ( 'PRIN' ) ( 'SJOB' ) ( 'SPOS' ) ).
  CALL FUNCTION 'RS_SET_SELSCREEN_STATUS'
    EXPORTING
      p_status  = sy-pfkey
    TABLES
      p_exclude = lt_excl.

  LOOP AT SCREEN.
    IF screen-group1 = 'HID'.
      screen-active = '0'.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

  IF go_dash IS NOT BOUND.
    go_dash = NEW #( ).
    go_dash->run( ).
  ELSEIF gv_reload = abap_true.
    go_dash->run( ).
  ENDIF.
  CLEAR gv_reload.

*----------------------------------------------------------------------*
AT SELECTION-SCREEN.
  CASE sscrfields-ucomm.
    WHEN 'ZEIDRILL'.                   "Click inside the dashboard
      IF go_dash IS BOUND.
        go_dash->handle_action( go_dash->mv_action ).
      ENDIF.
    WHEN 'FC01' OR space OR 'ONLI'.    "Refresh button / Enter
      gv_reload = abap_true.
  ENDCASE.

*----------------------------------------------------------------------*
START-OF-SELECTION.
  "Not used - the dashboard is displayed on the selection screen
