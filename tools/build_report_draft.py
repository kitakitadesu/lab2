#!/usr/bin/env python3
"""Build Lab 2.2 Stepper Motor Thai draft report from Report+Format.docx."""
import os
import re
import shutil
import struct
import tempfile
import zipfile
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(REPO, "Report+Format.docx")
SIMULINK_PNG = os.path.join(REPO, "stepper_data", "report_final", "Simulink_MotorXploer_Stepper.png")
OUT_DOCX = os.path.join(REPO, "Lab2_2_Stepper_Motor_Report_Draft.docx")
WORK_DIR = os.path.join(tempfile.gettempdir(), "stepper_report_build")

FONT = "TH Sarabun New"
PRINTABLE_W = 9746  # A4 (11906) - left(1080) - right(1080) twips


def rpr(sz=32, bold=False, italic=False, color=None, font=FONT):
    parts = [
        f'<w:rFonts w:ascii="{font}" w:eastAsia="{font}" w:hAnsi="{font}" w:cs="{font}"/>'
    ]
    if bold:
        parts.append("<w:b/><w:bCs/>")
    if italic:
        parts.append("<w:i/><w:iCs/>")
    if color:
        parts.append(f'<w:color w:val="{color}"/>')
    parts.append(f'<w:sz w:val="{sz}"/><w:szCs w:val="{sz}"/>')
    return "<w:rPr>" + "".join(parts) + "</w:rPr>"


def run(text, sz=32, bold=False, italic=False, color=None, font=FONT):
    return f'<w:r>{rpr(sz, bold, italic, color, font)}<w:t xml:space="preserve">{escape(text)}</w:t></w:r>'


def p(
    runs_xml,
    before=0,
    after=0,
    jc="thaiDistribute",
    first_line=0,
    left=0,
    num_id=None,
    ilvl=0,
    style=None,
    keep_next=False,
    tabs_xml="",
    page_break_before=False,
):
    ppr = []
    if style:
        ppr.append(f'<w:pStyle w:val="{style}"/>')
    if keep_next:
        ppr.append("<w:keepNext/>")
    if page_break_before:
        ppr.append("<w:pageBreakBefore/>")
    if num_id is not None:
        ppr.append(f'<w:numPr><w:ilvl w:val="{ilvl}"/><w:numId w:val="{num_id}"/></w:numPr>')
    if tabs_xml:
        ppr.append(f"<w:tabs>{tabs_xml}</w:tabs>")
    sp = f'<w:spacing w:before="{before}" w:after="{after}" w:line="240" w:lineRule="auto"/>'
    ppr.append(sp)
    if first_line or left:
        attrs = []
        if left:
            attrs.append(f'w:left="{left}"')
        if first_line:
            attrs.append(f'w:firstLine="{first_line}"')
        ppr.append(f'<w:ind {" ".join(attrs)}/>')
    if jc:
        ppr.append(f'<w:jc w:val="{jc}"/>')
    return f"<w:p><w:pPr>{''.join(ppr)}</w:pPr>{runs_xml}</w:p>"


def h_lab(text, page_break=False):
    return p(
        run(text, sz=36, bold=True),
        before=0,
        after=120,
        jc="center",
        keep_next=True,
        page_break_before=page_break,
    )


def h_exp(text, page_break=False):
    return p(
        run(text, sz=32, bold=True),
        before=240,
        after=0,
        jc="thaiDistribute",
        keep_next=True,
        page_break_before=page_break,
    )


def h_sec(text):
    return p(run(text, sz=32, bold=True), before=240, after=0, jc="thaiDistribute", keep_next=True)


def h_sub(text):
    return p(run(text, sz=32, bold=True), before=120, after=0, jc="thaiDistribute", keep_next=True)


def body_p(text, is_first=False, italic=False, color=None):
    return p(
        run(text, sz=32, italic=italic, color=color),
        before=0 if is_first else 240,
        after=0,
        jc="thaiDistribute",
        first_line=720,
    )


def body_runs(runs_xml, is_first=False):
    return p(
        runs_xml,
        before=0 if is_first else 240,
        after=0,
        jc="thaiDistribute",
        first_line=720,
    )


def bullet_p(text, num_id=1, left=360, bold_prefix=None):
    if bold_prefix:
        rx = run(bold_prefix, sz=32, bold=True) + run(text, sz=32)
    else:
        rx = run(text, sz=32)
    return p(rx, before=0, after=0, jc="thaiDistribute", num_id=num_id, left=left)


def var_head(text, num_id):
    return p(
        run(text, sz=32, bold=True),
        before=0,
        after=0,
        jc="thaiDistribute",
        style="ListParagraph",
        num_id=num_id,
    )


def var_item(text):
    return p(
        run(text, sz=32),
        before=0,
        after=0,
        jc="thaiDistribute",
        style="ListParagraph",
        num_id=49,
    )


def link_p(url):
    return p(run(url, sz=32), before=0, after=0, jc="left")


def caption(label, text, before=60, after=120):
    rx = run(label + " ", sz=28, bold=True) + run(text, sz=28)
    return p(rx, before=before, after=after, jc="center")


def page_break_p():
    return '<w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:br w:type="page"/></w:r></w:p>'


# --- OMML equation builders (12 pt = sz 24 per manual) ---
def mr(text, roman=False):
    rpr_m = f'<w:rPr><w:rFonts w:ascii="Cambria Math" w:hAnsi="Cambria Math" w:cs="{FONT}"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>'
    mpr = "<m:rPr><m:nor/></m:rPr>" if roman else ""
    return f"<m:r>{mpr}{rpr_m}<m:t>{escape(text)}</m:t></m:r>"


def msub(base_xml, sub_xml):
    return f"<m:sSub><m:e>{base_xml}</m:e><m:sub>{sub_xml}</m:sub></m:sSub>"


def mfrac(num_xml, den_xml):
    return f"<m:f><m:num>{num_xml}</m:num><m:den>{den_xml}</m:den></m:f>"


def md_delim(inner_xml, beg="(", end=")"):
    return f'<m:d><m:dPr><m:begChr m:val="{escape(beg)}"/><m:endChr m:val="{escape(end)}"/></m:dPr><m:e>{inner_xml}</m:e></m:d>'


def mnary(chr_val, sub_xml, sup_xml, expr_xml):
    return (
        f'<m:nary><m:naryPr><m:chr m:val="{chr_val}"/><m:limLoc m:val="subSup"/></m:naryPr>'
        f"<m:sub>{sub_xml}</m:sub><m:sup>{sup_xml}</m:sup><m:e>{expr_xml}</m:e></m:nary>"
    )


def eq_p(omath_inner, eq_num):
    tabs = f'<w:tab w:val="center" w:pos="{PRINTABLE_W // 2}"/><w:tab w:val="right" w:pos="{PRINTABLE_W}"/>'
    tab_r = f"<w:r>{rpr(sz=24)}<w:tab/></w:r>"
    num_r = run(f"({eq_num})", sz=24)
    return p(
        f"{tab_r}<m:oMath>{omath_inner}</m:oMath>{tab_r}{num_r}",
        before=120,
        after=120,
        jc="left",
        tabs_xml=tabs,
    )


# --- Table builder (14 pt = sz 28 per manual) ---
def make_table(headers, rows, col_widths, alignments=None):
    if alignments is None:
        alignments = ["center"] * len(headers)
    grid = "".join(f'<w:gridCol w:w="{w}"/>' for w in col_widths)
    tbl_pr = (
        "<w:tblPr>"
        '<w:tblStyle w:val="TableGrid"/>'
        f'<w:tblW w:w="{sum(col_widths)}" w:type="dxa"/>'
        '<w:jc w:val="center"/>'
        "<w:tblCellMar>"
        '<w:top w:w="60" w:type="dxa"/><w:bottom w:w="60" w:type="dxa"/>'
        '<w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/>'
        "</w:tblCellMar>"
        "</w:tblPr>"
    )

    def cell(text, w, align, bold=False, shade=None):
        shd = f'<w:shd w:val="clear" w:color="auto" w:fill="{shade}"/>' if shade else ""
        tc_pr = f'<w:tcPr><w:tcW w:w="{w}" w:type="dxa"/>{shd}<w:vAlign w:val="center"/></w:tcPr>'
        lines = text.split("\n")
        ps = "".join(
            p(run(ln, sz=28, bold=bold), before=0, after=0, jc=align) for ln in lines
        )
        return f"<w:tc>{tc_pr}{ps}</w:tc>"

    hdr_cells = "".join(
        cell(h, w, "center", bold=True, shade="E8EEF5")
        for h, w in zip(headers, col_widths)
    )
    tr_xml = [f"<w:tr><w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>{hdr_cells}</w:tr>"]
    for row in rows:
        rc = "".join(
            cell(val, w, al, bold=False)
            for val, w, al in zip(row, col_widths, alignments)
        )
        tr_xml.append(f"<w:tr><w:trPr><w:cantSplit/></w:trPr>{rc}</w:tr>")
    return f"<w:tbl>{tbl_pr}<w:tblGrid>{grid}</w:tblGrid>{''.join(tr_xml)}</w:tbl>"


def placeholder_box(title, bullets):
    tbl_pr = (
        "<w:tblPr>"
        f'<w:tblW w:w="{PRINTABLE_W}" w:type="dxa"/>'
        '<w:jc w:val="center"/>'
        "<w:tblBorders>"
        '<w:top w:val="dashed" w:sz="6" w:space="0" w:color="7F7F7F"/>'
        '<w:left w:val="dashed" w:sz="6" w:space="0" w:color="7F7F7F"/>'
        '<w:bottom w:val="dashed" w:sz="6" w:space="0" w:color="7F7F7F"/>'
        '<w:right w:val="dashed" w:sz="6" w:space="0" w:color="7F7F7F"/>'
        "</w:tblBorders>"
        "<w:tblCellMar>"
        '<w:top w:w="140" w:type="dxa"/><w:bottom w:w="140" w:type="dxa"/>'
        '<w:left w:w="180" w:type="dxa"/><w:right w:w="180" w:type="dxa"/>'
        "</w:tblCellMar>"
        "</w:tblPr>"
    )
    ps = [p(run(title, sz=28, bold=True, color="404040"), before=0, after=60, jc="center")]
    for b in bullets:
        ps.append(p(run(b, sz=28, italic=True, color="595959"), before=0, after=0, jc="center"))
    tc = (
        f'<w:tc><w:tcPr><w:tcW w:w="{PRINTABLE_W}" w:type="dxa"/>'
        '<w:shd w:val="clear" w:color="auto" w:fill="F7F7F7"/></w:tcPr>'
        f"{''.join(ps)}</w:tc>"
    )
    return f'<w:tbl>{tbl_pr}<w:tblGrid><w:gridCol w:w="{PRINTABLE_W}"/></w:tblGrid><w:tr><w:trPr><w:cantSplit/></w:trPr>{tc}</w:tr></w:tbl>'


def image_p(rid, cx_emu, cy_emu, docpr_id=201, name="SimulinkModel"):
    return (
        "<w:p><w:pPr>"
        '<w:spacing w:before="120" w:after="60" w:line="240" w:lineRule="auto"/>'
        '<w:jc w:val="center"/>'
        "</w:pPr><w:r><w:rPr><w:noProof/></w:rPr><w:drawing>"
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        f'<wp:extent cx="{cx_emu}" cy="{cy_emu}"/>'
        '<wp:effectExtent l="0" t="0" r="0" b="0"/>'
        f'<wp:docPr id="{docpr_id}" name="{name}"/>'
        "<wp:cNvGraphicFramePr>"
        '<a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/>'
        "</wp:cNvGraphicFramePr>"
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        "<pic:nvPicPr>"
        f'<pic:cNvPr id="{docpr_id}" name="{name}"/>'
        '<pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr>'
        "</pic:nvPicPr>"
        "<pic:blipFill>"
        f'<a:blip r:embed="{rid}"/>'
        "<a:stretch><a:fillRect/></a:stretch>"
        "</pic:blipFill>"
        "<pic:spPr>"
        f'<a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx_emu}" cy="{cy_emu}"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
        "</pic:spPr>"
        "</pic:pic></a:graphicData></a:graphic>"
        "</wp:inline></w:drawing></w:r></w:p>"
    )


def build_content(cover_p0_xml):
    el = []

    # ==================== COVER PAGE ====================
    el.append(cover_p0_xml)
    el.append(p("", before=0, after=0, jc="left"))
    el.append(p(run("LAB 2: Actuators (Lab 2.2: Stepper Motor)", sz=32, bold=True), before=0, after=0, jc="left"))
    el.append(p(run("Name", sz=32, bold=True), before=240, after=0, jc="left"))
    for _ in range(3):
        el.append(
            p(
                run("นาย/นางสาว xxx xxx 673405000xx", sz=32),
                before=0,
                after=0,
                jc="left",
                num_id=1,
                tabs_xml='<w:tab w:val="left" w:pos="2268"/>',
            )
        )
    el.append(p(run("Objectives", sz=32, bold=True), before=240, after=0, jc="left"))
    cover_objs = [
        "เพื่อศึกษาหลักการทำงาน โครงสร้าง ชนิดของโรเตอร์ และโหมดการขับเคลื่อนของ Stepper Motor ร่วมกับไดรเวอร์ DRV8825",
        "เพื่อวิเคราะห์ความสัมพันธ์ระหว่างความถี่สัญญาณขับ (STEP Frequency) กับความเร็วรอบของมอเตอร์ในแต่ละโหมดการขับเคลื่อน",
        "เพื่อศึกษาปรากฏการณ์ Loss Step เงื่อนไขที่ก่อให้เกิดการสูญเสียก้าว และผลของความเร่ง (Acceleration) ต่อความถี่สูงสุดก่อนเกิด Loss Step",
        "เพื่อเปรียบเทียบข้อดี ข้อเสีย และความเหมาะสมของการเลือกใช้โหมดการขับเคลื่อนแต่ละแบบในงานจริง",
        "เพื่อประยุกต์ใช้ MATLAB และ Simulink ในการส่งคำสั่ง ควบคุมโหมด บันทึกข้อมูล และตรวจสอบความสอดคล้องระหว่างผลวัดจริงกับทฤษฎี",
    ]
    for obj in cover_objs:
        el.append(p(run(obj, sz=32), before=0, after=0, jc="thaiDistribute", num_id=1))

    # ==================== MAIN LAB HEADING ====================
    el.append(h_lab("2. Lab 2.2: Stepper Motor", page_break=True))

    # =========================================================================
    # EXPERIMENT 1: Drive Modes & Frequency-Speed Relationship (R1-R5, R7, R9-R13)
    # =========================================================================
    el.append(h_exp("การทดลองที่ 1 การศึกษาโหมดการขับเคลื่อนและความสัมพันธ์ระหว่างความถี่สัญญาณขับกับความเร็วรอบของ Stepper Motor"))

    # --- จุดประสงค์ ---
    el.append(h_sec("จุดประสงค์"))
    exp1_objs = [
        "เพื่อสังเกตการทำงานจริงและเปรียบเทียบลักษณะการเคลื่อนที่ของ Stepper Motor ในแต่ละโหมดที่ไดรเวอร์ DRV8825 รองรับ ได้แก่ Full Step, Half Step และ Microstep (1/4, 1/8, 1/16, 1/32)",
        "เพื่อวัดและวิเคราะห์ความสัมพันธ์ระหว่างความถี่ของสัญญาณพัลส์ขับ (STEP Frequency) กับความเร็วรอบของมอเตอร์ในแต่ละโหมดการขับเคลื่อน",
        "เพื่อตรวจสอบความสอดคล้องระหว่างความเร็วรอบที่วัดได้จาก Incremental Encoder (AMT103-V) กับความเร็วรอบตามสมการทฤษฎี รวมถึงประเมินความซ้ำได้ของการวัด",
    ]
    for item in exp1_objs:
        el.append(bullet_p(item, num_id=52, left=360))

    # --- สมมติฐาน ---
    el.append(h_sec("สมมติฐาน"))
    el.append(
        body_p(
            "เมื่อมอเตอร์หมุนโดยยังไม่เกิดการสูญเสียก้าว (Loss Step) ความเร็วรอบของ Stepper Motor จะแปรผันตรงกับความถี่ของสัญญาณ STEP ที่ป้อนให้ไดรเวอร์ และแปรผกผันกับตัวคูณไมโครสเต็ป (Microstep Factor) ของโหมดที่เลือกใช้งาน หากคงความถี่สัญญาณ STEP ไว้เท่าเดิม การเปลี่ยนจากโหมด Full Step ไปเป็น Half Step หรือ Microstep ที่ละเอียดขึ้นจะทำให้มุมหมุนต่อหนึ่งพัลส์เล็กลง ความเร็วรอบจึงลดลงตามสัดส่วนของตัวคูณไมโครสเต็ป ในขณะเดียวกันการเคลื่อนที่จะนุ่มนวลและสั่นสะเทือนน้อยลง",
            is_first=True,
        )
    )

    # --- ตัวแปร ---
    el.append(h_sec("ตัวแปร"))
    el.append(var_head("ตัวแปรต้น:", num_id=56))
    el.append(var_item("โหมดการขับเคลื่อนของไดรเวอร์ DRV8825 กำหนดผ่านขา M0, M1, M2 จำนวน 6 โหมด ได้แก่ Full Step (1), Half Step (1/2), 1/4, 1/8, 1/16 และ 1/32"))
    el.append(var_item("ความถี่สัญญาณขับ STEP (Stepper Frequency) ในช่วง 200 ถึง 1,600 Hz (ขั้นละ 200 Hz, ค้างระดับละ 4 วินาที) ผ่านอัตราเร่งจำกัดที่ 2,000 Hz/s"))
    el.append(var_head("ตัวแปรตาม:", num_id=56))
    el.append(var_item("ความเร็วเชิงมุมที่วัดได้จาก Encoder (rad/s) และความเร็วรอบจริง (RPM)"))
    el.append(var_item("ลักษณะการเคลื่อนที่จริงในแต่ละโหมด ได้แก่ ความนุ่มนวล เสียง และการสั่นสะเทือนของเพลา"))
    el.append(var_head("ตัวแปรควบคุม:", num_id=56))
    el.append(var_item("ชุดมอเตอร์และบอร์ดทดลอง MotorXplorer เดิม แรงดันแหล่งจ่าย 24 V จาก Adapter และค่าจำกัดกระแส (Current Limit) ของ DRV8825 คงที่ตลอดการทดลอง"))
    el.append(var_item("สภาวะโหลดเปล่า (No-load) ทิศทางการหมุน (DIR = 0) ค่าจำกัดความเร่ง (2,000 Hz/s) และคาบเวลาเก็บข้อมูลใน Simulink (Fixed-step 0.001 s)"))

    # --- เอกสารและงานวิจัยที่เกี่ยวข้อง (R1, R2, R5) ---
    el.append(h_sec("เอกสารและงานวิจัยที่เกี่ยวข้อง"))

    el.append(h_sub("1. หลักการทำงานและประเภทของ Stepper Motor"))
    el.append(
        body_p(
            "Stepper Motor เป็นมอเตอร์ไฟฟ้ากระแสตรงแบบไร้แปรงถ่านที่แบ่งการหมุนหนึ่งรอบเต็มออกเป็นขั้นมุมย่อยเท่าๆ กัน เรียกว่ามุมก้าว (Step Angle) โครงสร้างหลักประกอบด้วยสเตเตอร์ (Stator) ที่มีชุดขดลวดแม่เหล็กไฟฟ้าวางเรียงเป็นเฟส และโรเตอร์ (Rotor) ที่หมุนตามแนวแรงแม่เหล็ก เมื่อจ่ายกระแสให้ขดลวดสเตเตอร์ตามลำดับเวลา ขั้วแม่เหล็กของโรเตอร์จะจัดแนวเข้าหาขั้วสเตเตอร์ที่กำลังมีกระแสไหล ส่งผลให้เพลาหมุนไปทีละก้าวตามจำนวนพัลส์ที่ป้อนเข้าโดยไม่จำเป็นต้องใช้วงจรป้อนกลับตำแหน่งในสภาวะที่โหลดไม่เกินพิกัด",
            is_first=True,
        )
    )
    el.append(
        body_p(
            "ในเชิงโครงสร้างของโรเตอร์ Stepper Motor แบ่งออกเป็น 3 ชนิดหลัก ชนิดแรกคือ Variable Reluctance (VR) โรเตอร์เป็นเหล็กอ่อนที่มีซี่ฟันโดยไม่มีแม่เหล็กถาวร อาศัยหลักการลดความต้านทานแม่เหล็กจึงไม่มี Detent Torque ชนิดที่สองคือ Permanent Magnet (PM) โรเตอร์เป็นแม่เหล็กถาวรสลับขั้วเหนือ-ใต้ ให้แรงบิดค่อนข้างสูงที่ความเร็วต่ำแต่มุมก้าวค่อนข้างกว้างราว 7.5 ถึง 15 องศา ชนิดที่สามคือ Hybrid Stepper Motor รวมข้อดีของทั้งสองแบบไว้ด้วยกัน โรเตอร์มีแกนแม่เหล็กถาวรประกบด้วยฝาครอบเหล็กอ่อนที่มีซี่ฟันละเอียด ทำให้ได้มุมก้าวเล็กมาตรฐานที่ 1.8 องศาต่อก้าว (200 ก้าวเต็มต่อรอบ) และให้แรงบิดยึดสูง มอเตอร์ที่ใช้บนบอร์ด MotorXplorer ในการทดลองนี้เป็นชนิด Hybrid 2 เฟส แบบ Bipolar (สาย 4 เส้น แยกเป็นเฟส A และเฟส B) [ตรวจสอบมุมก้าวจาก Datasheet ของมอเตอร์บนโต๊ะทดลองอีกครั้ง หากไม่ใช่ 1.8 องศา ให้ปรับค่าตามจริง]",
        )
    )
    el.append(
        body_p(
            "หากจำแนกตามลักษณะการพันขดลวดและวงจรขับ Stepper Motor แบ่งเป็นแบบ Unipolar ที่มีจุดต่อกึ่งกลาง (Center Tap) ทำให้จ่ายกระแสทิศทางเดียวผ่านสวิตช์อย่างง่ายได้แต่ใช้พื้นที่ทองแดงเพียงครึ่งหนึ่งต่อขณะ และแบบ Bipolar ที่ไม่มีจุดต่อกึ่งกลาง ต้องขับผ่านวงจร H-Bridge เพื่อกลับทิศกระแสในแต่ละเฟส ข้อได้เปรียบของแบบ Bipolar คือใช้ขดลวดเต็มทั้งเฟสจึงให้แรงบิดสูงกว่าในขนาดตัวถังเท่ากัน ส่วนพารามิเตอร์แรงบิดสถิตสำคัญมีสองค่าคือ Holding Torque แรงบิดสูงสุดที่โรเตอร์ต้านแรงภายนอกได้ขณะจ่ายกระแสพิกัดค้างไว้ และ Detent Torque แรงบิดต้านทานการหมุนขณะไม่จ่ายไฟซึ่งเกิดจากแรงดึงดูดระหว่างแม่เหล็กถาวรของโรเตอร์กับฟันเหล็กสเตเตอร์",
        )
    )

    # Eq (1) Full steps per rev
    eq1 = msub(mr("N"), mr("full", roman=True)) + mr("=") + mfrac(mr("360°", roman=True), msub(mr("θ"), mr("step", roman=True)))
    el.append(eq_p(eq1, 1))
    el.append(
        body_p(
            "โดย N_full คือจำนวนก้าวเต็มต่อรอบ (Steps/Revolution) และ θ_step คือมุมก้าวเต็มของมอเตอร์ (องศา) สำหรับมอเตอร์มุมก้าว 1.8 องศา จะได้ N_full = 200 ก้าวต่อรอบ",
            is_first=True,
        )
    )

    el.append(h_sub("2. หลักการขับเคลื่อนในแต่ละโหมด (Drive Modes) และตารางความจริงของ DRV8825"))
    el.append(
        body_p(
            "รูปแบบการจ่ายกระแสเข้าขดลวดเฟส A และเฟส B กำหนดความละเอียดของมุมหมุน แรงบิด และความนุ่มนวลของการเคลื่อนที่ โหมดมาตรฐานของ Stepper Motor มี 4 รูปแบบ ได้แก่ Wave Drive (One-Phase On) จ่ายกระแสทีละเฟสเดียวสลับไปมา (A+ -> B+ -> A- -> B-) ใช้พลังงานต่ำกว่าแต่ได้แรงบิดราวร้อยละ 70 ของโหมด Full Step โหมด Full Step (Two-Phase On) จ่ายกระแสเต็มพิกัดพร้อมกันทั้งสองเฟสทุกจังหวะ โรเตอร์จึงจัดแนวอยู่กึ่งกลางระหว่างขั้วทั้งสองและให้ Holding Torque สูงสุด โหมด Half Step สลับระหว่างการจ่าย 1 เฟสกับ 2 เฟส (8 จังหวะต่อรอบไฟฟ้า) ทำให้ความละเอียดเพิ่มขึ้นเป็น 2 เท่าที่ 400 พัลส์ต่อรอบแต่แรงบิดในจังหวะ 1 เฟสจะต่ำกว่าจังหวะ 2 เฟสราวร้อยละ 29 และโหมด Microstepping ใช้การควบคุมกระแสแบบ PWM ในสัดส่วนไซน์และโคไซน์ (I_A = I_max cos φ, I_B = I_max sin φ) เพื่อแบ่งหนึ่งก้าวเต็มออกเป็นก้าวย่อย 1/4, 1/8, 1/16 จนถึง 1/32 ทำให้การเคลื่อนที่ต่อเนื่องและลดการสั่นสะเทือนช่วงเรโซแนนซ์ได้อย่างชัดเจน",
            is_first=True,
        )
    )
    el.append(
        body_p(
            "สำหรับบอร์ดทดลองที่ใช้ชิปขับ DRV8825 ตัวชิปออกแบบวงจรภายในให้ควบคุมด้วยสัญญาณ STEP, DIR, EN และขากำหนดโหมด M0, M1, M2 โดยรองรับตั้งแต่ Full Step (Two-Phase On) ไปจนถึง 1/32 Microstep ตามตารางที่ 1 ทั้งนี้ DRV8825 ไม่รองรับโหมด Wave Drive (One-Phase On) เนื่องจากวงจร Indexer ภายในจ่ายกระแสแบบสองเฟสพร้อมกันตั้งแต่โหมดเริ่มต้น (M2 M1 M0 = 000)",
        )
    )

    # Table 1: DRV8825 Drive Modes & Truth Table (R2)
    el.append(caption("ตารางที่ 1", "เปรียบเทียบโหมดการขับเคลื่อนและการกำหนดขา M0, M1, M2 ของไดรเวอร์ DRV8825 (กรณีมอเตอร์ 1.8°/step, 200 ก้าว/รอบ)", before=120, after=60))
    t1_headers = ["โหมดการขับเคลื่อน", "M2", "M1", "M0", "ตัวคูณไมโครสเต็ป (M)", "พัลส์ต่อรอบ (pulses/rev)", "มุมต่อพัลส์ (°/pulse)", "การรองรับบน DRV8825"]
    t1_rows = [
        ["Wave Drive (1-Phase On)", "-", "-", "-", "1", "200", "1.8000", "ไม่รองรับ"],
        ["Full Step (2-Phase On)", "0", "0", "0", "1", "200", "1.8000", "รองรับ"],
        ["Half Step (1/2)", "0", "0", "1", "2", "400", "0.9000", "รองรับ"],
        ["1/4 Microstep", "0", "1", "0", "4", "800", "0.4500", "รองรับ"],
        ["1/8 Microstep", "0", "1", "1", "8", "1,600", "0.2250", "รองรับ"],
        ["1/16 Microstep", "1", "0", "0", "16", "3,200", "0.1125", "รองรับ"],
        ["1/32 Microstep", "1", "0", "1", "32", "6,400", "0.05625", "รองรับ (110, 111 = 1/32)"],
    ]
    el.append(make_table(t1_headers, t1_rows, [1950, 620, 620, 620, 1280, 1360, 1250, 2046], ["left", "center", "center", "center", "center", "center", "center", "center"]))
    el.append(p("", before=0, after=60, jc="left"))

    el.append(h_sub("3. ความสัมพันธ์ระหว่างความถี่สัญญาณขับกับความเร็วรอบ"))
    el.append(
        body_p(
            "ทุกขอบขาขึ้นของสัญญาณ STEP หนึ่งพัลส์ทำให้สนามแม่เหล็กสเตเตอร์เลื่อนไปข้างหน้าหนึ่งก้าวย่อยเป็นมุม θ_pulse = θ_step / M ดังนั้นจำนวนพัลส์ที่ต้องใช้ในการหมุนครบหนึ่งรอบเต็มคือ N_pulse = M · N_full เมื่อป้อนพัลส์อย่างต่อเนื่องด้วยความถี่ f_step (Hz หรือ พัลส์ต่อวินาที) และโรเตอร์หมุนตามสนามแม่เหล็กได้โดยไม่หลุดซิงโครไนซ์ ความเร็วรอบตามทฤษฎีของเพลาจะคำนวณได้จากสมการที่ (2) และ (3)",
            is_first=True,
        )
    )

    # Eq (2) Pulses per rev & step angle per pulse
    eq2 = (
        msub(mr("N"), mr("pulse", roman=True))
        + mr("=")
        + mr("M")
        + mr("⋅")
        + msub(mr("N"), mr("full", roman=True))
        + mr(",   ", roman=True)
        + msub(mr("θ"), mr("pulse", roman=True))
        + mr("=")
        + mfrac(msub(mr("θ"), mr("step", roman=True)), mr("M"))
    )
    el.append(eq_p(eq2, 2))

    # Eq (3) Theoretical RPM
    eq3 = (
        msub(mr("ω"), mr("theory", roman=True))
        + mr("=")
        + mfrac(msub(mr("f"), mr("step", roman=True)) + mr("×") + mr("60", roman=True), mr("M") + mr("⋅") + msub(mr("N"), mr("full", roman=True)))
        + mr("  (RPM)", roman=True)
    )
    el.append(eq_p(eq3, 3))

    # Eq (4) Measured RPM from encoder
    eq4 = (
        msub(mr("ω"), mr("meas", roman=True))
        + mr("=")
        + mfrac(md_delim(msub(mr("ω"), mr("enc", roman=True)), "|", "|") + mr("×") + mr("60", roman=True), mr("2π", roman=True))
        + mr("  (RPM)", roman=True)
    )
    el.append(eq_p(eq4, 4))

    el.append(
        body_p(
            "สมการที่ (3) แสดงให้เห็นชัดว่าเหตุใดความเร็วรอบจึงเปลี่ยนตามความถี่ของสัญญาณขับ เนื่องจากความถี่ f_step คืออัตราการสับเปลี่ยนสถานะสนามแม่เหล็กสเตเตอร์ต่อวินาที โรเตอร์ซึ่งยึดแนวตามแรงแม่เหล็กจะก้าวตามทุกพัลส์ที่เข้ามา เมื่อความถี่เพิ่มขึ้นสองเท่า เวลาต่อหนึ่งก้าวลดลงครึ่งหนึ่ง ความเร็วรอบจึงเพิ่มขึ้นสองเท่าตามสัดส่วน ในทางกลับกันเมื่อเพิ่มตัวคูณไมโครสเต็ป M เป็นสองเท่า ระยะเชิงมุมต่อพัลส์ลดลงครึ่งหนึ่ง จึงต้องใช้พัลส์มากเป็นสองเท่าเพื่อให้หมุนครบหนึ่งรอบ ความเร็วรอบที่ความถี่เดียวกันจึงลดลงครึ่งหนึ่ง",
            is_first=True,
        )
    )

    # --- ขั้นตอนการดำเนินงาน (R11) ---
    el.append(h_sec("ขั้นตอนการดำเนินงาน"))
    exp1_steps = [
        "ติดตั้งโมดูล Stepper Motor เข้ากับฐานบอร์ด MotorXplorer ขันสกรูยึดฐาน 4 ตัว และขันสกรูตัวหนอนที่ Coupling ยึดเพลามอเตอร์เข้ากับเพลา Incremental Encoder AMT103-V ให้แน่น แล้วลองหมุนเพลาด้วยมือเพื่อตรวจว่าไม่ติดขัด",
        "ตรวจสอบคู่สายเฟส A และเฟส B ของ Stepper Motor ด้วยมัลติมิเตอร์โหมด Continuity (สายในเฟสเดียวกันจะมีเสียงบี๊บ) แล้วต่อเข้ากับขั้ว Terminal ชุด Stepper บนบอร์ดทดลอง",
        "ต่อสายจัมเปอร์เชื่อมต่อ Encoder AMT103-V (5V->3V3, GND->GND, A->PA7, B->PA6) และไดรเวอร์ DRV8825 (M0->PB15, M1->PB14, M2->PB13, EN->PB1, DIR->PB2, STEP->PC8) เข้ากับบอร์ด Nucleo STM32G474RE",
        "ตรวจสอบความปลอดภัยก่อนจ่ายไฟ โดยปรับจัมเปอร์ 5V_SEL บนบอร์ด STM32G474RE ไปที่ตำแหน่ง E5V ตรวจแรงดันขาออกจาก Step Down ให้ได้ 3.3 V และตรวจสอบค่าจำกัดกระแส (Current Limit) ของ DRV8825 ให้อยู่ในพิกัดมอเตอร์ จากนั้นต่อ Adapter 24 V และสาย USB เข้ากับคอมพิวเตอร์",
        "แฟลชเฟิร์มแวร์ motorxplorer.bin ลงบอร์ด Nucleo-G474RE ตรวจสอบว่า LED กระพริบที่ความถี่ประมาณ 1 Hz จากนั้นเปิดไฟล์ MotorXploer_Stepper.slx ใน MATLAB/Simulink ตั้งค่า COM Port ของบล็อก Host Serial Setup, Host Serial Rx1 และ Host Serial Tx ให้ตรงกับ ST-Link Virtual COM Port (Baud rate 2,000,000, 8N1)",
        "กำหนดค่าเริ่มต้นในกรอบ Output to Nucleo-G474RE ให้ EN = 1 (ปิดขับมอเตอร์ขณะไม่ใช้งานเพื่อป้องกันความร้อนสะสม) และ DIR = 0 จากนั้นเปิดใช้งานบล็อก R4 freq sweep (ตั้ง levels = [200 400 600 800 1000 1200 1400 1600 0] Hz, dwell = 4 s), R8 accel limit (2,000 Hz/s), R4 speed vs freq และ R14 drive mode โดยกด Uncomment เฉพาะบล็อกที่ใช้งาน",
        "เลือกโหมดการขับเคลื่อนที่ R14 drive mode เริ่มจาก Full Step เปลี่ยน EN เป็น 0 แล้วกด Run สังเกตลักษณะการหมุน เสียง และการสั่นสะเทือน พร้อมบันทึกสัญญาณ f_cmd, Stepper Frequency (echo), R4_rpm_theory และ R4_rpm_meas ผ่าน Simulation Data Inspector เมื่อครบโปรไฟล์ (32 วินาที ความถี่กลับเป็น 0 Hz) ให้กด Stop และเปลี่ยน EN กลับเป็น 1 ทันที",
        "ทำซ้ำข้อ 7 ให้ครบทั้ง 6 โหมดที่ DRV8825 รองรับ (Full Step, 1/2, 1/4, 1/8, 1/16, 1/32) โดยแต่ละโหมดทดลองซ้ำ 3 ครั้ง (Trial 1 ถึง 3) เพื่อนำมาหาค่าเฉลี่ย ส่วนเบี่ยงเบนมาตรฐาน และร้อยละความคลาดเคลื่อนเทียบค่าทฤษฎี",
    ]
    for st in exp1_steps:
        el.append(bullet_p(st, num_id=53, left=360))

    # --- ผลการทดลอง (R3, R4, R9) ---
    el.append(h_sec("ผลการทดลอง"))
    el.append(
        body_p(
            "ผลการทดสอบความเร็วรอบของ Stepper Motor ในแต่ละโหมดการขับเคลื่อนที่ความถี่สัญญาณขับต่างๆ เปรียบเทียบระหว่างค่าทฤษฎีจากสมการที่ (3) กับค่าเฉลี่ยจากการวัดจริงซ้ำ 3 ครั้ง แสดงในตารางที่ 2 และผลการสังเกตลักษณะการเคลื่อนที่จริงของมอเตอร์ในแต่ละโหมดแสดงในตารางที่ 3",
            is_first=True,
        )
    )

    # Table 2: Exp 1 Frequency vs Speed per Drive Mode (R4 + R9 repeat trials)
    el.append(caption("ตารางที่ 2", "ผลการวัดความเร็วรอบของ Stepper Motor เทียบค่าทฤษฎีในแต่ละโหมดการขับเคลื่อน (ทำซ้ำ 3 ครั้ง, กรณี 200 ก้าว/รอบ)", before=120, after=60))
    t2_headers = ["โหมด\n(M)", "ความถี่\n(Hz)", "ทฤษฎี\n(RPM)", "ครั้งที่ 1\n(RPM)", "ครั้งที่ 2\n(RPM)", "ครั้งที่ 3\n(RPM)", "ค่าเฉลี่ย ± SD\n(RPM)", "Error\n(%)"]
    t2_rows = []
    modes_t2 = [("Full (1)", 1), ("Half (2)", 2), ("1/4 (4)", 4), ("1/8 (8)", 8), ("1/16 (16)", 16), ("1/32 (32)", 32)]
    freqs_t2 = [200, 400, 800, 1200, 1600]
    for mlabel, mval in modes_t2:
        for i, fq in enumerate(freqs_t2):
            rpm_th = fq * 60.0 / (mval * 200.0)
            rpm_str = f"{rpm_th:.2f}" if rpm_th >= 10 else f"{rpm_th:.3f}"
            t2_rows.append([mlabel if i == 0 else "", str(fq), rpm_str, "[...]", "[...]", "[...]", "[... ± ...]", "[...]"])
    el.append(make_table(t2_headers, t2_rows, [1150, 950, 1050, 1050, 1050, 1050, 2346, 1100], ["center"] * 8))
    el.append(p("", before=0, after=60, jc="left"))

    # Placeholder for Graph 1 (R4)
    el.append(
        placeholder_box(
            "[รอแทรกกราฟจากการทดลองจริง: ภาพที่ 1]",
            [
                "กราฟความสัมพันธ์ระหว่างความถี่สัญญาณขับ (Hz) บนแกน X กับความเร็วรอบ (RPM) บนแกน Y",
                "แสดงเส้นค่าทฤษฎี (เส้นประ) เทียบกับจุดค่าวัดจริงเฉลี่ยพร้อมแถบ SD ของทั้ง 6 โหมด (Full, 1/2, 1/4, 1/8, 1/16, 1/32)",
                "ส่งออกข้อมูล R4_rpm_theory, R4_rpm_meas และ Stepper Frequency (echo) จาก Simulation Data Inspector แล้วพล็อตด้วย MATLAB",
            ],
        )
    )
    el.append(caption("ภาพที่ 1", "กราฟเปรียบเทียบความเร็วรอบตามทฤษฎีกับความเร็วรอบที่วัดได้จริงเทียบความถี่สัญญาณขับในแต่ละโหมดการขับเคลื่อน", before=60, after=120))

    # Table 3: Real Operation Qualitative Comparison (R3)
    el.append(caption("ตารางที่ 3", "ผลการสังเกตการทำงานจริงและความแตกต่างของการเคลื่อนที่ในแต่ละโหมดที่ไดรเวอร์ DRV8825 รองรับ", before=60, after=60))
    t3_headers = ["โหมดการขับเคลื่อน", "ความนุ่มนวลของการหมุน", "ระดับเสียงและการสั่นสะเทือน", "ลักษณะการเคลื่อนที่ที่ความถี่ต่ำ (200 Hz)", "หมายเหตุเพิ่มเติมจากหน้างาน"]
    t3_rows = [
        ["Full Step (M=1)", "[บันทึกการสังเกตจริง]", "[บันทึกการสังเกตจริง]", "[เห็นจังหวะก้าวชัด / สั่นมากที่สุด]", "[...]"],
        ["Half Step (M=2)", "[บันทึกการสังเกตจริง]", "[บันทึกการสังเกตจริง]", "[นุ่มนวลขึ้นกว่า Full Step]", "[...]"],
        ["1/4 Microstep (M=4)", "[บันทึกการสังเกตจริง]", "[บันทึกการสังเกตจริง]", "[...]", "[...]"],
        ["1/8 Microstep (M=8)", "[บันทึกการสังเกตจริง]", "[บันทึกการสังเกตจริง]", "[...]", "[...]"],
        ["1/16 Microstep (M=16)", "[บันทึกการสังเกตจริง]", "[บันทึกการสังเกตจริง]", "[...]", "[...]"],
        ["1/32 Microstep (M=32)", "[บันทึกการสังเกตจริง]", "[บันทึกการสังเกตจริง]", "[หมุนต่อเนื่องเรียบที่สุด / ช้าที่สุดที่ความถี่เท่ากัน]", "[...]"],
    ]
    el.append(make_table(t3_headers, t3_rows, [1750, 1950, 2000, 2346, 1700], ["left", "left", "left", "left", "left"]))
    el.append(p("", before=0, after=60, jc="left"))

    # Placeholder for Real Operation Photo / SDI Waveforms (R3)
    el.append(
        placeholder_box(
            "[รอแทรกภาพจากการทดลองจริง: ภาพที่ 2]",
            [
                "ภาพหน้าจอ Simulation Data Inspector เปรียบเทียบสัญญาณความเร็วรอบ (R3_rpm_meas หรือ R4_rpm_meas) ตามเวลา",
                "ของโหมด Full Step, Half Step และ 1/16 หรือ 1/32 Microstep เพื่อแสดงความต่างของความเรียบสัญญาณและระดับความเร็วที่ความถี่เดียวกัน",
                "(หากมีภาพถ่ายชุดทดลองขณะมอเตอร์หมุนหรือลิงก์วิดีโอใน GitHub สามารถอ้างอิงเพิ่มเติมได้)",
            ],
        )
    )
    el.append(caption("ภาพที่ 2", "กราฟเปรียบเทียบสัญญาณความเร็วรอบที่วัดได้จริงจาก Encoder ระหว่างโหมด Full Step, Half Step และ Microstep", before=60, after=120))

    # --- สรุปผลการทดลอง 1 (R12) ---
    el.append(h_sec("สรุปผลการทดลอง"))
    el.append(
        body_p(
            "[รอเติมตัวเลขสรุปจากการทดลองจริง] จากการทดลองขับ Stepper Motor ผ่านไดรเวอร์ DRV8825 ทั้ง 6 โหมดในช่วงความถี่ 200 ถึง 1,600 Hz พบว่าความเร็วรอบของมอเตอร์แปรผันตรงกับความถี่สัญญาณขับเป็นเส้นตรงในทุกโหมดตลอดช่วงที่มอเตอร์ไม่หลุดก้าว โดยโหมด Full Step ให้ความเร็วรอบสูงสุด (เช่น ที่ 800 Hz วัดได้เฉลี่ย [...] RPM เทียบทฤษฎี 240.00 RPM) และเมื่อเพิ่มความละเอียดไมโครสเต็ปเป็น 1/2, 1/4, 1/8, 1/16 และ 1/32 ความเร็วรอบที่ความถี่เดียวกันลดลงทีละครึ่งตามตัวคูณ M สอดคล้องกับสมการที่ (3) โดยมีค่าความคลาดเคลื่อนเฉลี่ยร้อยละ [...] และค่าเบี่ยงเบนมาตรฐานระหว่างการทำซ้ำ 3 ครั้งไม่เกิน [...] RPM ด้านลักษณะการเคลื่อนที่จริง โหมด Microstep (1/8 ถึง 1/32) หมุนได้นุ่มนวลและเงียบกว่าโหมด Full Step อย่างชัดเจน ซึ่งยืนยันสมมติฐานที่ตั้งไว้",
            is_first=True,
        )
    )

    # --- อภิปรายผล 1 (R3, R4, R5, R7, R9) ---
    el.append(h_sec("อภิปรายผล"))
    el.append(
        body_p(
            "พฤติกรรมที่ความเร็วรอบเพิ่มขึ้นเป็นเส้นตรงตามความถี่สัญญาณ STEP เกิดจากธรรมชาติการทำงานแบบซิงโครนัสของ Stepper Motor ทุกหนึ่งพัลส์ที่ขา STEP บังคับให้เวกเตอร์สนามแม่เหล็กสเตเตอร์หมุนไปหนึ่งก้าวย่อยคงที่ โรเตอร์จึงต้องหมุนตามด้วยอัตราเร็วเชิงมุมเท่ากับอัตราป้อนพัลส์หารด้วยจำนวนพัลส์ต่อรอบ หากเปรียบเทียบความชันของกราฟความเร็วรอบต่อความถี่ในภาพที่ 1 โหมดที่ใช้ตัวคูณ M สูงกว่าจะให้เส้นกราฟที่ชันน้อยกว่าเป็นสัดส่วน 1/M พอดี ทั้งนี้ความคลาดเคลื่อนเล็กน้อยที่อาจปรากฏในข้อมูลวัดจริง (ร้อยละ [...]) มักมาจากความละเอียดการหาอนุพันธ์ความเร็วจาก Encoder ที่ความเร็วต่ำมากในโหมด 1/16 และ 1/32 การสั่นสะเทือนเชิงมุมขณะเปลี่ยนก้าวในโหมด Full Step หรือความคลาดเคลื่อนของคาบเวลาการส่งข้อมูล UART ที่ความถี่สูง",
            is_first=True,
        )
    )
    el.append(
        body_p(
            "การทำซ้ำ 3 ครั้งในแต่ละโหมดให้ค่าส่วนเบี่ยงเบนมาตรฐานต่ำ ([...] RPM) แสดงให้เห็นความเที่ยงตรงของการควบคุมแบบวงเปิดตราบเท่าที่มอเตอร์ยังทำงานต่ำกว่าขีดจำกัดแรงบิด อย่างไรก็ดี เมื่อพิจารณาการเลือกใช้งานจริงแต่ละโหมดมีจุดเด่นและข้อจำกัดต่างกันอย่างชัดเจน ดังสรุปเปรียบเทียบในตารางที่ 4 ซึ่งรวมโหมด Wave Drive ไว้ในเชิงทฤษฎีแม้ว่าไดรเวอร์ DRV8825 จะไม่รองรับโหมดดังกล่าวก็ตาม",
        )
    )

    # Table 4: Pros & Cons per Drive Mode (R7)
    el.append(caption("ตารางที่ 4", "เปรียบเทียบข้อดี ข้อเสีย และความเหมาะสมในการใช้งานจริงของแต่ละโหมดการขับเคลื่อน Stepper Motor", before=120, after=60))
    t4_headers = ["โหมดการขับเคลื่อน", "ข้อดี", "ข้อเสีย", "ลักษณะงานที่เหมาะสม"]
    t4_rows = [
        [
            "Wave Drive\n(1-Phase On)",
            "จ่ายกระแสทีละเฟสจึงกินไฟและความร้อนต่ำกว่า Full Step วงจรควบคุมพื้นฐานไม่ซับซ้อน",
            "แรงบิดลดลงเหลือราวร้อยละ 70 ของ Full Step มุมก้าวหยาบ สั่นสะเทือนสูง และ DRV8825 ไม่รองรับ",
            "งานโหลดเบามากที่จำกัดกำลังไฟฟ้าจากแบตเตอรี่และไม่ต้องการความละเอียดสูง",
        ],
        [
            "Full Step\n(2-Phase On)",
            "ให้ Holding Torque สูงสุดเต็มพิกัด 100% ทำความเร็วรอบได้สูงที่สุดที่ความถี่พัลส์เท่ากัน และประหยัดแบนด์วิดท์ของสัญญาณ STEP",
            "การเคลื่อนที่เป็นจังหวะกระตุก เสียงดัง สั่นสะเทือนสูง เกิดเรโซแนนซ์ที่ความถี่กลางได้ง่าย ความละเอียดตำแหน่งหยาบ (1.8°/pulse)",
            "งานที่เน้นแรงบิดและความเร็วรอบสูงโดยไม่เข้มงวดเรื่องเสียงหรือความละเอียดมุม เช่น ระบบลำเลียงทั่วไป",
        ],
        [
            "Half Step\n(1/2)",
            "เพิ่มความละเอียดตำแหน่งเป็น 2 เท่าของ Full Step (0.9°/pulse) ลดการสั่นและเรโซแนนซ์ได้ระดับหนึ่งโดยใช้ความถี่สัญญาณเพิ่มเพียง 2 เท่า",
            "แรงบิดสลับไม่สม่ำเสมอระหว่างจังหวะ 1 เฟส (~70%) กับ 2 เฟส (100%) ทำให้ยังมีแรงกระเพื่อม (Torque Ripple)",
            "งานวางตำแหน่งทั่วไปที่ต้องการจุดสมดุลระหว่างแรงบิด ความเร็ว และความนุ่มนวล",
        ],
        [
            "Microstep\n(1/4, 1/8, 1/16, 1/32)",
            "เคลื่อนที่นุ่มนวลมาก เสียงเบา ลดแรงสั่นสะเทือนและปัญหาเรโซแนนซ์ช่วงความถี่ต่ำ-กลางได้อย่างชัดเจน เพิ่มความละเอียดการสั่งตำแหน่งได้สูงถึง 0.05625°/pulse",
            "แรงบิดต่อหนึ่งก้าวย่อย (Incremental Torque) ลดลงตามตัวคูณ M จึงคลาดเคลื่อนตำแหน่งได้ง่ายเมื่อมีแรงเสียดทานสูง ต้องใช้ความถี่สัญญาณ STEP สูงมากเพื่อให้ได้ความเร็วรอบเท่าเดิม (อาจติดขีดจำกัด Timer ของไมโครคอนโทรลเลอร์)",
            "เครื่องพิมพ์ 3 มิติ เครื่อง CNC แขนกลขนาดเล็ก และระบบจัดตำแหน่งเชิงแสงที่ต้องการความนุ่มนวลและความละเอียดสูง",
        ],
    ]
    el.append(make_table(t4_headers, t4_rows, [1600, 2750, 2900, 2496], ["left", "left", "left", "left"]))
    el.append(p("", before=0, after=60, jc="left"))

    # =========================================================================
    # EXPERIMENT 2: Loss Step & Effect of Acceleration (R6, R8, R9-R13)
    # =========================================================================
    el.append(h_exp("การทดลองที่ 2 การศึกษาการเกิด Loss Step และผลของความเร่งต่อความถี่ที่เกิด Loss Step", page_break=True))

    # --- จุดประสงค์ ---
    el.append(h_sec("จุดประสงค์"))
    exp2_objs = [
        "เพื่อศึกษาหลักการ เงื่อนไข และลักษณะพฤติกรรมของ Stepper Motor เมื่อเกิดการสูญเสียก้าว (Loss Step) ทั้งในกรณีออกตัวแบบก้าวกระโดด (Step Input) และกรณีเพิ่มความถี่ต่อเนื่อง",
        "เพื่อวิเคราะห์ผลของอัตราเร่งเชิงเส้น (Linear Acceleration) ต่อความถี่สูงสุดที่มอเตอร์สามารถหมุนตามได้ก่อนเกิด Loss Step",
        "เพื่อวัดจำนวนก้าวที่สูญหาย (Lost Full Steps) จากความแตกต่างระหว่างจำนวนรอบที่สั่งกับจำนวนรอบจริงที่วัดได้จาก Encoder",
    ]
    for item in exp2_objs:
        el.append(bullet_p(item, num_id=54, left=360))

    # --- สมมติฐาน ---
    el.append(h_sec("สมมติฐาน"))
    el.append(
        body_p(
            "หากสั่งความถี่สัญญาณ STEP แบบก้าวกระโดดจากหยุดนิ่งไปยังความถี่เป้าหมายโดยไม่จำกัดความเร่ง มอเตอร์จะเกิด Loss Step ตั้งแต่ความถี่ค่อนข้างต่ำ (บริเวณ Start/Stop หรือ Pull-in Frequency) เนื่องจากแรงบิดของมอเตอร์ไม่พอเอาชนะความเฉื่อยของโรเตอร์ในเสี้ยววินาทีแรก ในทางกลับกันเมื่อใช้การเร่งความเร็วแบบเชิงเส้น (Linear Acceleration) ผ่านบล็อกจำกัดอัตราการเปลี่ยนแปลงความถี่ (Rate Limiter) ความต้องการแรงบิดเร่งความเฉื่อยจะลดลง มอเตอร์จึงไต่ความถี่ขึ้นไปสู่ย่าน Slew Range ได้สูงขึ้นก่อนจะเกิด Loss Step และยิ่งกำหนดอัตราเร่ง (Hz/s) ให้ต่ำลงในระดับที่เหมาะสม ความถี่สูงสุดก่อนเกิด Loss Step จะยิ่งขยับเข้าใกล้ขีดจำกัด Pull-out Frequency ของมอเตอร์มากขึ้น",
            is_first=True,
        )
    )

    # --- ตัวแปร ---
    el.append(h_sec("ตัวแปร"))
    el.append(var_head("ตัวแปรต้น:", num_id=57))
    el.append(var_item("รูปแบบและขนาดของความเร่งสัญญาณ STEP ได้แก่ กรณีไม่จำกัดความเร่ง (Step Input จาก 0 Hz ไปยังความถี่ทดสอบทันที โดย Comment Through บล็อก R8 accel limit) เทียบกับกรณีจำกัดความเร่งแบบเชิงเส้นหลายระดับ เช่น 500, 1,000, 2,000 และ 4,000 Hz/s"))
    el.append(var_item("ความถี่เป้าหมายของสัญญาณ STEP ที่เพิ่มขึ้นเพื่อหาความถี่วิกฤตซึ่งเริ่มเกิด Loss Step"))
    el.append(var_head("ตัวแปรตาม:", num_id=57))
    el.append(var_item("ความถี่สูงสุดก่อนเกิด Loss Step (Pull-in Frequency สำหรับกรณีไม่จำกัดความเร่ง และ Pull-out Frequency สำหรับกรณีมี Linear Acceleration)"))
    el.append(var_item("จำนวนก้าวเต็มที่สูญหาย (Lost Full Steps) และความเร็วรอบจริงที่วัดได้จาก Encoder"))
    el.append(var_head("ตัวแปรควบคุม:", num_id=57))
    el.append(var_item("โหมดการขับเคลื่อนคงที่ (กำหนดทดสอบหลักที่โหมด Full Step, M = 1 หรือโหมดที่เลือกเปรียบเทียบให้คงที่ตลอดชุดทดสอบ)"))
    el.append(var_item("ชุดฮาร์ดแวร์เดิม แรงดัน 24 V ค่า Current Limit ของ DRV8825 โหลดบนเพลา ทิศทาง DIR = 0 และเวลาสุ่มตัวอย่าง 0.001 s"))

    # --- เอกสารและงานวิจัยที่เกี่ยวข้อง (R6, R8) ---
    el.append(h_sec("เอกสารและงานวิจัยที่เกี่ยวข้อง"))

    el.append(h_sub("1. หลักการของ Loss Step และเงื่อนไขที่ทำให้เกิด Loss Step"))
    el.append(
        body_p(
            "Loss Step หรือการหลุดซิงโครไนซ์เกิดขึ้นเมื่อมุมตำแหน่งจริงของโรเตอร์ตามมุมสนามแม่เหล็กสเตเตอร์ไม่ทันเกินครึ่งหนึ่งของรอบไฟฟ้า (มากกว่า ±2 ก้าวเต็ม หรือ ±90 องศาไฟฟ้า) จนแรงดึงแม่เหล็กไม่สามารถดึงโรเตอร์กลับเข้าก้าวเดิมได้ ผลที่ตามมาคือโรเตอร์กระตุกถอยหลัง ชะงัก หรือสั่นอยู่กับที่แม้ไดรเวอร์ยังคงส่งพัลส์ STEP ต่อไป เนื่องจากระบบขับ Stepper Motor พื้นฐานทำงานแบบวงเปิด ไดรเวอร์จึงไม่รับรู้ว่าตำแหน่งจริงคลาดเคลื่อนไปแล้ว ในการทดลองนี้จึงใช้สัญญาณจาก Incremental Encoder เปรียบเทียบกับจำนวนรอบที่สั่งจริงจากสัญญาณ f_echo เพื่อคำนวณจำนวนก้าวเต็มที่สูญหายตามสมการที่ (5)",
            is_first=True,
        )
    )

    # Eq (5) Lost Full Steps
    int1 = mnary("∫", mr("0", roman=True), mr("t"), mfrac(msub(mr("f"), mr("echo", roman=True)) + md_delim(mr("τ")), mr("M") + mr("⋅") + msub(mr("N"), mr("full", roman=True))) + mr(" dτ"))
    int2 = md_delim(mnary("∫", mr("0", roman=True), mr("t"), mfrac(msub(mr("ω"), mr("enc", roman=True)) + md_delim(mr("τ")), mr("2π", roman=True)) + mr(" dτ")), "|", "|")
    eq5 = msub(mr("S"), mr("lost", roman=True)) + md_delim(mr("t")) + mr("=") + md_delim(int1 + mr("−") + int2) + mr("⋅") + msub(mr("N"), mr("full", roman=True))
    el.append(eq_p(eq5, 5))

    el.append(
        body_p(
            "เงื่อนไขหลักทางฟิสิกส์ที่นำไปสู่การเกิด Loss Step อธิบายได้จากสมดุลแรงบิดในสมการที่ (6) คือมอเตอร์จะหมุนตามคำสั่งได้ก็ต่อเมื่อแรงบิดที่มอเตอร์สร้างได้ ณ ความถี่นั้นไม่น้อยกว่าผลรวมของแรงบิดโหลดภายนอกกับแรงบิดที่ใช้เร่งความเฉื่อยของโรเตอร์และเพลาต่อพ่วง",
            is_first=True,
        )
    )

    # Eq (6) Dynamic Torque Condition
    eq6 = (
        msub(mr("T"), mr("motor", roman=True))
        + md_delim(mr("f"))
        + mr("≥")
        + msub(mr("T"), mr("load", roman=True))
        + mr("+")
        + msub(mr("J"), mr("total", roman=True))
        + mr("⋅")
        + mr("α")
        + mr(",   ", roman=True)
        + mr("α")
        + mr("=")
        + mfrac(mr("2π", roman=True), mr("M") + mr("⋅") + msub(mr("N"), mr("full", roman=True)))
        + mr("⋅")
        + mfrac(mr("d") + msub(mr("f"), mr("step", roman=True)), mr("dt"))
    )
    el.append(eq_p(eq6, 6))

    el.append(
        body_p(
            "จากสมการที่ (6) ปัจจัยที่ทำให้เกิด Loss Step สรุปได้ 5 ประการหลัก ประการแรกคือความถี่ขับสูงเกินไป ที่ความถี่สูงแรงดันต้านกลับ (Back-EMF) เพิ่มขึ้นตามความเร็วและเวลาในการชาร์จกระแสผ่านค่าความเหนี่ยวนำขดลวด (L · di/dt) สั้นลง กระแสจริงในขดลวดจึงขึ้นไม่ถึงค่าพิกัด ทำให้แรงบิดของมอเตอร์ตกอย่างรวดเร็ว ประการที่สองคืออัตราเร่งสูงเกินไปหรือออกตัวแบบก้าวกระโดด ทำให้พจน์ความเฉื่อย J_total · α สูงเกินแรงบิดที่มี ประการที่สามคือแรงบิดโหลดภายนอกหรือความเฉื่อยต่อพ่วงสูงเกินกราฟ Torque-Speed ประการที่สี่คือการตั้งค่า Current Limit ของไดรเวอร์ต่ำเกินไปหรือแรงดันแหล่งจ่ายไม่พอ และประการที่ห้าคือการสั่นพ้องเชิงกล (Mid-band Resonance) ในช่วงความถี่กลางที่ความถี่พัลส์ตรงกับความถี่ธรรมชาติของโรเตอร์จนมุมแกว่งขยายตัวและหลุดก้าว",
        )
    )

    el.append(h_sub("2. Start/Stop Frequency, Slew Range และ Linear Acceleration"))
    el.append(
        body_p(
            "เส้นโค้งลักษณะเฉพาะระหว่างแรงบิดกับความเร็ว (Torque-Speed Characteristic Curve) ของ Stepper Motor แบ่งย่านการทำงานออกเป็นสองขอบเขตสำคัญ ขอบเขตแรกคือเส้น Pull-in Torque (Start/Stop Region) แสดงแรงบิดและความถี่สูงสุดที่มอเตอร์สามารถออกตัวจากหยุดนิ่งหรือหยุดกะทันหันได้ทันทีโดยไม่หลุดก้าว ขอบเขตที่สองคือเส้น Pull-out Torque (Slew Region) ซึ่งสูงกว่า Pull-in อย่างมาก มอเตอร์ไม่สามารถออกตัวตรงเข้าย่าน Slew ได้ทันทีแต่สามารถไต่ขึ้นไปทำงานในย่านนี้ได้หากค่อยๆ เพิ่มความถี่ด้วยโปรไฟล์ความเร่งเชิงเส้น (Linear Acceleration Ramp) เพื่อให้พจน์ J_total · α มีค่าพอเหมาะกับแรงบิดคงเหลือในแต่ละความถี่ การลดอัตราการเพิ่มความถี่ df/dt จึงช่วยขยายความถี่ใช้งานสูงสุดของมอเตอร์ได้โดยไม่ต้องเปลี่ยนฮาร์ดแวร์",
            is_first=True,
        )
    )

    # --- ขั้นตอนการดำเนินงาน 2 (R11) ---
    el.append(h_sec("ขั้นตอนการดำเนินงาน"))
    exp2_steps = [
        "ใช้ชุดฮาร์ดแวร์และการตั้งค่า Serial ใน MotorXploer_Stepper.slx ต่อเนื่องจากการทดลองที่ 1 ตั้งค่าโหมดการขับเคลื่อนคงที่ (เช่น Full Step: M2=0, M1=0, M0=0) และตรวจสอบให้ EN = 1 ก่อนเริ่มปรับพารามิเตอร์ทุกครั้ง",
        "ทดสอบหาความถี่ Pull-in (กรณีไม่จำกัดความเร่ง): ปิดบล็อก R4 freq sweep และ R8 accel limit ด้วย Comment Through (Ctrl+Shift+Y) เพื่อให้ค่าจากบล็อก Stepper Frequency ส่งตรงเข้าบอร์ด เปิดใช้งานบล็อก R6 lost steps เพื่อติดตามค่า R6_lost_steps และเปิด R12 results scope หากต้องการดูกราฟแบบเรียลไทม์",
        "กำหนดค่า Stepper Frequency จากต่ำไปสูงทีละขั้น (เช่น 200, 400, 600, 800, 1,000 Hz ขึ้นไป) โดยก่อนทดสอบแต่ละความถี่ให้มอเตอร์หยุดนิ่งแล้วเปลี่ยน EN เป็น 0 เพื่อออกตัวแบบก้าวกระโดด สังเกตอาการหมุนและค่า R6_lost_steps หากมอเตอร์ชะงักหรือค่า Lost Steps เพิ่มขึ้นต่อเนื่อง ให้บันทึกความถี่วิกฤตที่เริ่มเกิด Loss Step จากนั้นปรับความถี่ละเอียดขึ้นเพื่อหาขอบเขต Pull-in ที่แม่นยำ ทำซ้ำ 3 ครั้ง",
        "ทดสอบผลของความเร่งเชิงเส้น (Linear Acceleration): เปิดใช้งานบล็อก R4 freq sweep (ปรับ levels ให้ไล่ความถี่สูงขึ้นจนครอบคลุมจุดหลุดก้าว เช่น [200 400 600 800 1000 1200 1400 1600 2000 2400 2800 0] Hz, dwell = 3 s) ร่วมกับบล็อก R8 accel limit และ R8 lost steps",
        "ตั้งค่าพารามิเตอร์ accel ในบล็อก R8 accel limit ทีละระดับ ได้แก่ 4,000, 2,000, 1,000 และ 500 Hz/s กด Run ด้วย EN = 0 เพื่อบันทึกสัญญาณ f_cmd, Stepper Frequency (echo), rpm_meas และ R8_lost_steps ใน Simulation Data Inspector บันทึกความถี่สูงสุดก่อนที่ความเร็ววัดจริงจะตกฮวบและค่า R8_lost_steps จะพุ่งขึ้น (Pull-out Frequency)",
        "ทำซ้ำการทดลองในแต่ละค่าความเร่งจำนวน 3 ครั้ง (Trial 1 ถึง 3) โดยพักเปลี่ยน EN = 1 ระหว่างรอบเพื่อลดความร้อนสะสมของมอเตอร์และไดรเวอร์",
    ]
    for st in exp2_steps:
        el.append(bullet_p(st, num_id=55, left=360))

    # --- ผลการทดลอง 2 (R6, R8, R9) ---
    el.append(h_sec("ผลการทดลอง"))
    el.append(
        body_p(
            "ผลการหาความถี่สูงสุดก่อนเกิด Loss Step เปรียบเทียบระหว่างกรณีไม่จำกัดความเร่ง (Step Input) กับกรณีใช้ความเร่งเชิงเส้นที่อัตราต่างๆ จากการทดลองซ้ำ 3 ครั้ง แสดงในตารางที่ 5 และกราฟสัญญาณเวลาขณะเกิด Loss Step จาก Simulation Data Inspector แสดงในภาพที่ 3 และภาพที่ 4",
            is_first=True,
        )
    )

    # Table 5: Acceleration vs Max Frequency before Loss Step (R6, R8, R9)
    el.append(caption("ตารางที่ 5", "ความถี่สูงสุดก่อนเกิด Loss Step และจำนวนก้าวที่สูญหายเทียบกับอัตราเร่งเชิงเส้น (โหมด Full Step, ทำซ้ำ 3 ครั้ง)", before=120, after=60))
    t5_headers = ["เงื่อนไขความเร่ง\n(Hz/s)", "ครั้งที่ 1\n(Hz)", "ครั้งที่ 2\n(Hz)", "ครั้งที่ 3\n(Hz)", "ความถี่วิกฤตเฉลี่ย ± SD\n(Hz)", "ความเร็วรอบสูงสุด\n(RPM)", "อาการที่สังเกตเมื่อเกิด Loss Step"]
    t5_rows = [
        ["ไม่จำกัด (Step Input)", "[...]", "[...]", "[...]", "[... ± ...]", "[...]", "[ไม่ออกตัว / สั่นอยู่กับที่ทันที]"],
        ["4,000 Hz/s", "[...]", "[...]", "[...]", "[... ± ...]", "[...]", "[...]"],
        ["2,000 Hz/s", "[...]", "[...]", "[...]", "[... ± ...]", "[...]", "[...]"],
        ["1,000 Hz/s", "[...]", "[...]", "[...]", "[... ± ...]", "[...]", "[...]"],
        ["500 Hz/s", "[...]", "[...]", "[...]", "[... ± ...]", "[...]", "[...]"],
    ]
    el.append(make_table(t5_headers, t5_rows, [1650, 900, 900, 900, 1750, 1250, 2396], ["left", "center", "center", "center", "center", "center", "left"]))
    el.append(p("", before=0, after=60, jc="left"))

    el.append(
        placeholder_box(
            "[รอแทรกกราฟจากการทดลองจริง: ภาพที่ 3]",
            [
                "กราฟสัญญาณตามเวลาจาก Simulation Data Inspector ขณะเกิด Loss Step",
                "แสดง f_cmd (Hz), R4_rpm_theory / R12 rpm_theory เทียบกับ rpm_meas (RPM) และ R6_lost_steps / R8_lost_steps (full steps)",
                "ระบุจุดเวลาที่ความเร็ววัดจริงตกลงจากเส้นทฤษฎีและกราฟ Lost Steps เริ่มพุ่งขึ้นอย่างชัดเจน",
            ],
        )
    )
    el.append(caption("ภาพที่ 3", "กราฟแสดงความสัมพันธ์ระหว่างความถี่คำสั่ง ความเร็วรอบทฤษฎี ความเร็วรอบจริง และจำนวนก้าวที่สูญหายขณะเกิด Loss Step", before=60, after=120))

    el.append(
        placeholder_box(
            "[รอแทรกกราฟจากการทดลองจริง: ภาพที่ 4]",
            [
                "กราฟแท่งหรือกราฟเส้นแสดงความถี่สูงสุดก่อนเกิด Loss Step (Hz) เทียบกับอัตราเร่งเชิงเส้น (Step Input, 4000, 2000, 1000, 500 Hz/s)",
                "พร้อมแถบความคลาดเคลื่อน (Error Bar = ±SD จากการทำซ้ำ 3 ครั้ง)",
            ],
        )
    )
    el.append(caption("ภาพที่ 4", "ผลของอัตราเร่งเชิงเส้น (Acceleration Limit) ต่อความถี่สูงสุดของสัญญาณขับก่อนเกิด Loss Step", before=60, after=120))

    # --- สรุปผลการทดลอง 2 (R12) ---
    el.append(h_sec("สรุปผลการทดลอง"))
    el.append(
        body_p(
            "[รอเติมตัวเลขสรุปจากการทดลองจริง] จากการทดลองพบว่ากรณีสั่งความถี่แบบก้าวกระโดดโดยไม่จำกัดความเร่ง มอเตอร์เริ่มเกิด Loss Step ที่ความถี่เฉลี่ย [...] Hz (ค่า Pull-in Frequency) เมื่อเปิดใช้งานการจำกัดความเร่งแบบเชิงเส้นผ่านบล็อก R8 accel limit ความถี่สูงสุดที่มอเตอร์หมุนตามได้ก่อนเกิด Loss Step เพิ่มขึ้นเป็น [...] Hz ที่ความเร่ง 4,000 Hz/s, [...] Hz ที่ 2,000 Hz/s, [...] Hz ที่ 1,000 Hz/s และ [...] Hz ที่ 500 Hz/s ตามลำดับ แสดงชัดเจนว่าการควบคุมความเร่งช่วยให้มอเตอร์ข้ามผ่านขีดจำกัด Start/Stop เข้าสู่ย่านความเร็วสูง (Slew Range) ได้จริงตามสมมติฐาน",
            is_first=True,
        )
    )

    # --- อภิปรายผล 2 (R6, R8, R9) ---
    el.append(h_sec("อภิปรายผล"))
    el.append(
        body_p(
            "ความแตกต่างระหว่างความถี่วิกฤตในกรณี Step Input ([...] Hz) กับกรณีจำกัดความเร่งเชิงเส้น ([...] Hz) อธิบายได้โดยตรงจากสมการที่ (6) ขณะสั่งแบบก้าวกระโดด อัตราการเปลี่ยนความถี่ df/dt มีค่าสูงมากในจังหวะเริ่มต้น โรเตอร์ซึ่งหยุดนิ่งต้องใช้แรงบิดเร่งความเฉื่อย J_total · α เกินกว่าแรงบิดที่มอเตอร์สร้างได้ จึงหลุดซิงโครไนซ์ทันที เมื่อจำกัดอัตราเร่งให้ต่ำลง พจน์ J_total · α เล็กลง แรงบิดที่มอเตอร์ผลิตได้จึงเหลือพอสำหรับประคองให้โรเตอร์ค่อยๆ เร่งความเร็วตามสนามแม่เหล็กขึ้นไปได้สูงกว่าเดิมหลายเท่า",
            is_first=True,
        )
    )
    el.append(
        body_p(
            "อย่างไรก็ตามการลดอัตราเร่งลงมากเกินจุดหนึ่งจะไม่ทำให้ความถี่สูงสุดเพิ่มขึ้นต่อไปอย่างไม่มีขีดจำกัด เพราะเมื่อความถี่เข้าใกล้ขีดจำกัด Pull-out ของมอเตอร์ แม้ความเร่ง α จะเข้าใกล้ศูนย์ แรงดัน Back-EMF และค่าความเหนี่ยวนำของขดลวดก็จำกัดกระแสเฟสจนแรงบิดมอเตอร์ตกลงมาเท่ากับแรงบิดเสียดทานของเพลาและแบริ่ง (T_motor(f) = T_load) ณ จุดนี้โรเตอร์จะหลุดก้าวไม่ว่าจะเร่งช้าเพียงใด นอกจากนี้หากสังเกตพบการหลุดก้าวชั่วคราวในช่วงความถี่ต่ำถึงกลางก่อนที่มอเตอร์จะกลับไปหมุนได้ดีที่ความถี่สูงกว่า ปรากฏการณ์ดังกล่าวคือ Mid-band Resonance ซึ่งบรรเทาได้ด้วยการเปลี่ยนไปใช้โหมด Microstep (เช่น 1/8 หรือ 1/16) ร่วมกับอัตราเร่งที่เหมาะสม ด้านความน่าเชื่อถือของข้อมูล การทดลองซ้ำ 3 ครั้งให้ค่า SD ของความถี่วิกฤตเท่ากับ [...] Hz ชี้ว่าผลลัพธ์ทำซ้ำได้และสอดคล้องกับทฤษฎี Torque-Speed ของ Stepper Motor",
        )
    )

    # --- ข้อเสนอแนะ (R13) ---
    el.append(h_sec("ข้อเสนอแนะ"))
    suggestions = [
        "ควรตั้งค่า EN = 1 ใน Simulink ทุกครั้งหลังหยุดการทดลองแต่ละรอบ เพื่อตัดกระแสขับเข้าขดลวดและป้องกันความร้อนสะสมที่ตัวมอเตอร์และชิป DRV8825 ซึ่งอาจทำให้ความต้านทานขดลวดเปลี่ยนและส่งผลต่อความสม่ำเสมอของแรงบิดระหว่างการทดลองซ้ำ",
        "ควรเพิ่มการทดสอบภายใต้สภาวะมีโหลดเชิงกล (Load Torque) ร่วมกับชุด Load Cell เพื่อสร้างเส้นโค้ง Pull-in และ Pull-out Torque-Speed Curve จริงของมอเตอร์เปรียบเทียบกับ Datasheet",
        "การทดลองในโหมด Microstep ความละเอียดสูง (1/16 และ 1/32) ควรพิจารณาใช้ความถี่สัญญาณ STEP ที่กว้างขึ้นหรือทดสอบขีดจำกัดความถี่สูงสุดของ Timer (TIM20_CH3) บน STM32G474RE เพื่อแยกแยะระหว่างข้อจำกัดทางกลของมอเตอร์กับข้อจำกัดทางเฟิร์มแวร์",
        "สำหรับงานที่ต้องการความแม่นยำตำแหน่งสูงและห้ามเกิด Loss Step ควรนำสัญญาณ Encoder มาสร้างวงจรควบคุมแบบวงปิด (Closed-Loop Stepper) หรือใช้โปรไฟล์ความเร่งแบบ S-Curve เพื่อลดแรงกระตุก (Jerk) ในช่วงเริ่มและจบการเร่ง",
    ]
    for sg in suggestions:
        el.append(p(run(sg, sz=32), before=0, after=0, jc="thaiDistribute", num_id=1, left=360))

    # --- อ้างอิง (ใส่แค่ Link) (R13) ---
    el.append(h_sec("อ้างอิง"))
    refs = [
        "https://github.com/MINIFI2548/FRA271_LAB2_ACTUATOR_FRAB12",
        "https://www.ti.com/lit/ds/symlink/drv8825.pdf",
        "https://www.pololu.com/product/2982/faqs",
        "https://www.sameskydevices.com/product/resource/amt10.pdf",
        "https://www.orientalmotor.com/stepper-motors/technology/stepper-motor-basics.html",
        "https://www.ti.com/lit/an/slva488a/slva488a.pdf",
    ]
    for url in refs:
        el.append(link_p(url))

    # ==================== APPENDIX ก (R14 — does not count toward 45-page limit) ====================
    el.append(h_lab("ภาคผนวก ก: โปรแกรมและวงจรควบคุม Stepper Motor บน Simulink", page_break=True))

    el.append(h_sec("1. สถาปัตยกรรมฮาร์ดแวร์และการเชื่อมต่อสัญญาณ"))
    el.append(
        body_p(
            "ระบบควบคุมการทดลองใช้บอร์ด Nucleo STM32G474RE ทำงานร่วมกับเฟิร์มแวร์ motorxplorer.bin สื่อสารกับ MATLAB/Simulink ผ่านพอร์ตอนุกรม ST-Link Virtual COM Port (PA2/PA3) ที่อัตราบอด 2,000,000 bps (8-None-1) ด้วยแพ็กเก็ตไบนารีผ่านไลบรารี Waijung (Host Serial Setup, Host Serial Rx1, Host Serial Tx) โดยบอร์ดสร้างสัญญาณพัลส์ความถี่แปรผันออกทางขา PC8 (TIM20_CH3) ไปขับขา STEP ของไดรเวอร์ DRV8825 และอ่านความเร็วเชิงมุมของเพลาจาก Encoder AMT103-V ผ่าน Timer 3 (PA6/PA7) สรุปการเชื่อมต่อขาทั้งหมดในตารางที่ ก.1",
            is_first=True,
        )
    )

    el.append(caption("ตารางที่ ก.1", "สรุปการเชื่อมต่อขาสัญญาณระหว่าง Nucleo STM32G474RE กับ DRV8825 และ AMT103-V", before=120, after=60))
    ta1_headers = ["อุปกรณ์", "ขาอุปกรณ์", "ขา STM32G474RE", "หน้าที่และชนิดข้อมูลใน Simulink"]
    ta1_rows = [
        ["DRV8825", "STEP", "PC8 (TIM20_CH3)", "รับความถี่สัญญาณขับ (Stepper Frequency, ชนิด single)"],
        ["DRV8825", "M0, M1, M2", "PB15, PB14, PB13", "กำหนดโหมด Microstep 0-1 (ชนิด int16)"],
        ["DRV8825", "DIR", "PB2", "กำหนดทิศทางการหมุน 0/1 (ชนิด int16)"],
        ["DRV8825", "EN", "PB1", "เปิด/ปิดการจ่ายกระแสขับ 0 = เปิด, 1 = ปิด (ชนิด int16)"],
        ["AMT103-V", "A, B (5V, GND)", "PA7, PA6 (3V3, GND)", "อ่านความเร็วเชิงมุมเพลา (Motor Angular Velocity, rad/s, ชนิด single)"],
        ["ST-Link VCP", "UART TX/RX", "PA2, PA3", "สื่อสาร Simulink 2,000,000 bps 8N1 (Fixed-step 0.001 s)"],
    ]
    el.append(make_table(ta1_headers, ta1_rows, [1600, 1750, 2150, 4246], ["center", "center", "center", "left"]))
    el.append(p("", before=0, after=60, jc="left"))

    el.append(h_sec("2. โครงสร้างและแนวคิดการทำงานของไฟล์ MotorXploer_Stepper.slx"))
    el.append(
        body_p(
            "โมเดล MotorXploer_Stepper.slx พัฒนาต่อยอดจากไฟล์ต้นแบบ MotorXploer.slx โดยคงส่วนเชื่อมต่อบอร์ดด้านซ้าย (Input From Nucleo-G474RE และ Output to Nucleo-G474RE) พร้อมชนิดข้อมูลขาเข้า Host Serial Tx (single 3 ช่อง และ int16 5 ช่อง) ไว้เหมือนเดิมทุกประการ ส่วนการควบคุมและวิเคราะห์เพิ่มเติมด้านขวาออกแบบเป็น Atomic Subsystem แบบจบในตัวเอง (Sample Time คงที่ 0.001 s) แยกพื้นที่ตามหัวข้อการทดลอง R1 ถึง R14 แต่ละบล็อกรับเฉพาะสัญญาณจากบอร์ดผ่าน Goto/From Tag (omega, f_echo, M0, M1, M2) จึงเปิดหรือปิดเฉพาะบล็อกที่ต้องการใช้งานได้โดยไม่กระทบส่วนอื่น",
            is_first=True,
        )
    )
    el.append(
        body_p(
            "บล็อกทั้งหมดตั้งค่าเริ่มต้นเป็นปิดการใช้งานเพื่อให้โมเดลปลอดภัยและทำงานเหมือนไฟล์ต้นแบบ (EN = 1 ปิดมอเตอร์) เมื่อต้องการใช้งาน แบ่งออกเป็นสองกลุ่ม ได้แก่ กลุ่มบล็อกวิเคราะห์ (R1, R2, R3, R4 speed vs freq, R5, R6, R8 lost steps, R12 scope) ที่ปิดไว้ด้วย Comment Out (สลับเปิด/ปิดด้วย Ctrl+Shift+X) และกลุ่มบล็อกสั่งการที่วางคั่นระหว่างค่าคงที่ต้นแบบกับขาเข้าบอร์ด (R4 freq sweep, R8 accel limit, R14 drive mode) ซึ่งปิดไว้ด้วย Comment Through (Ctrl+Shift+Y) เพื่อส่งผ่านค่าจากกรอบต้นแบบตรงไปยังบอร์ดเมื่อไม่ได้ใช้งาน แต่เมื่อ Uncomment บล็อกเหล่านี้จะเข้าควบคุมสัญญาณแทนทันที ดังสรุปในตารางที่ ก.2 และแสดงผังวงจรในภาพที่ ก.1",
        )
    )

    el.append(caption("ตารางที่ ก.2", "สรุปหน้าที่ของแต่ละ Subsystem ในโมเดล MotorXploer_Stepper.slx และการตั้งค่าพารามิเตอร์", before=120, after=60))
    ta2_headers = ["ชื่อบล็อก (พื้นที่)", "ประเภท / ค่าเริ่มต้น", "แนวคิดการทำงานและพารามิเตอร์ที่ปรับได้"]
    ta2_rows = [
        ["R1 step angle to steps per rev", "วิเคราะห์ / Comment Out", "คำนวณจำนวนก้าวเต็มต่อรอบ 360 / 1.8 = 200 ก้าว/รอบ"],
        ["R2 microstep decode (DRV8825)", "วิเคราะห์ / Comment Out", "ใช้ 3-D Direct Lookup Table ถอดรหัสขา M0, M1, M2 เป็นตัวคูณไมโครสเต็ป (1 ถึง 32), พัลส์ต่อรอบ และมุมต่อพัลส์"],
        ["R3 measured motion", "วิเคราะห์ / Comment Out", "แปลงสัญญาณ omega (single -> double) คูณ 1/(2π) และ 60 เป็นความเร็วรอบจริง R3_rpm_meas พร้อมอินทิเกรตหาจำนวนรอบเพลา R3_shaft_rev"],
        ["R4 freq sweep (overrides f)", "สั่งการ / Comment Through", "สร้างโปรไฟล์ความถี่ขั้นบันไดด้วย Digital Clock (0.001 s) และ 1-D LUT (Flat/Clip) ดับเบิลคลิกปรับพารามิเตอร์ levels (Hz) และ dwell (s) ได้"],
        ["R4 speed vs freq / R5 theory speed", "วิเคราะห์ / Comment Out", "คำนวณความเร็วรอบทฤษฎี f_echo × 60 / (M × 200) เทียบกับความเร็วรอบวัดจริง และบันทึกสัญญาณลง Data Inspector"],
        ["R6 lost steps / R8 lost steps", "วิเคราะห์ / Comment Out", "อินทิเกรตความเร็วสั่งจาก f_echo เทียบกับค่าสัมบูรณ์ของจำนวนรอบเพลาจริง แล้วคูณ 200 เพื่อรายงานจำนวนก้าวเต็มที่สูญหาย (Lost Full Steps)"],
        ["R8 accel limit (overrides f)", "สั่งการ / Comment Through", "จำกัดความชันความถี่ด้วย Rate Limiter แบบดิสครีต ดับเบิลคลิกปรับพารามิเตอร์ accel (Hz/s, ค่าเริ่มต้น 2,000 Hz/s) สำหรับทดลองผลของความเร่ง"],
        ["R12 results scope", "วิเคราะห์ / Comment Out", "แสดงกราฟเรียลไทม์ 3 แกนพร้อมกัน ได้แก่ rpm_theory, rpm_meas และ lost_steps"],
        ["R14 drive mode (overrides M2 M1 M0)", "สั่งการ / Comment Through", "เมนูเลือกโหมดขับ 6 โหมด (Full Step ถึง 1/32) แปลงผ่าน 2-D Direct Lookup Table และ Demux ส่งออกขา M0, M1, M2 ตามตารางความจริง DRV8825"],
    ]
    el.append(make_table(ta2_headers, ta2_rows, [2450, 1950, 5346], ["left", "center", "left"]))
    el.append(p("", before=0, after=60, jc="left"))

    # Simulink model screenshot at 6.5 in (5943600 EMU) wide, aspect ratio from the PNG header
    with open(SIMULINK_PNG, "rb") as fh:
        png_w, png_h = struct.unpack(">II", fh.read(24)[16:24])
    cx = 5943600
    cy = int(round(cx * png_h / png_w))
    el.append(image_p("rId15", cx, cy, docpr_id=201, name="MotorXploer_Stepper"))
    el.append(caption("ภาพที่ ก.1", "ผังบล็อกไดอะแกรม Simulink (MotorXploer_Stepper.slx) แสดงส่วนเชื่อมต่อบอร์ด MotorXplorer และ Subsystem แบบแยกอิสระตามเกณฑ์ R1 ถึง R14", before=60, after=120))

    return "".join(el)


def patch_numbering(num_xml):
    # Add dedicated decimal numIds (52..55 -> abstractNumId 15, 56..57 -> abstractNumId 50)
    # with startOverride=1 so every numbered list starts cleanly at 1.
    additions = []
    for nid, abs_id in [(52, 15), (53, 15), (54, 15), (55, 15), (56, 50), (57, 50)]:
        additions.append(
            f'<w:num w:numId="{nid}">'
            f'<w:abstractNumId w:val="{abs_id}"/>'
            '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride>'
            "</w:num>"
        )
    idx = num_xml.rfind("</w:numbering>")
    assert idx != -1
    return num_xml[:idx] + "".join(additions) + num_xml[idx:]


def patch_footer(ftr_xml):
    # Ensure PAGE field in bottom-right footer explicitly uses TH Sarabun New 14 pt (sz=28)
    page_rpr = rpr(sz=28, font=FONT)
    ftr_xml = ftr_xml.replace(
        '<w:r><w:instrText xml:space="preserve"> PAGE   \\* MERGEFORMAT </w:instrText></w:r>',
        f'<w:r>{page_rpr}<w:instrText xml:space="preserve"> PAGE   \\* MERGEFORMAT </w:instrText></w:r>',
    )
    ftr_xml = ftr_xml.replace(
        "<w:r><w:rPr><w:noProof/></w:rPr><w:t>2</w:t></w:r>",
        f"<w:r>{page_rpr}<w:t>1</w:t></w:r>",
    )
    return ftr_xml


def main():
    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR)

    with zipfile.ZipFile(TEMPLATE, "r") as zf:
        zf.extractall(WORK_DIR)

    # Read template document.xml
    doc_path = os.path.join(WORK_DIR, "word", "document.xml")
    doc_xml = open(doc_path, "r", encoding="utf-8").read()

    # Extract exact cover P0 (logo + divider rule), body open tag, and sectPr
    body_open_m = re.search(r"^(.*?<w:body>)", doc_xml, flags=re.S)
    sect_m = re.search(r"(<w:sectPr\b.*?</w:sectPr>)\s*</w:body></w:document>", doc_xml, flags=re.S)
    p0_m = re.search(r"<w:p\b.*?</w:p>", doc_xml[body_open_m.end():], flags=re.S)
    assert body_open_m and sect_m and p0_m, "Failed to parse template document.xml"

    prefix = body_open_m.group(1)
    cover_p0 = p0_m.group(0)
    sect_pr = sect_m.group(1)

    new_body = build_content(cover_p0)
    new_doc_xml = f"{prefix}{new_body}{sect_pr}</w:body></w:document>"
    ET.fromstring(new_doc_xml.encode("utf-8"))  # XML well-formedness check
    open(doc_path, "w", encoding="utf-8").write(new_doc_xml)

    # Patch numbering.xml
    num_path = os.path.join(WORK_DIR, "word", "numbering.xml")
    new_num = patch_numbering(open(num_path, "r", encoding="utf-8").read())
    ET.fromstring(new_num.encode("utf-8"))
    open(num_path, "w", encoding="utf-8").write(new_num)

    # Patch footer1.xml (TH Sarabun New 14 pt)
    ftr_path = os.path.join(WORK_DIR, "word", "footer1.xml")
    new_ftr = patch_footer(open(ftr_path, "r", encoding="utf-8").read())
    ET.fromstring(new_ftr.encode("utf-8"))
    open(ftr_path, "w", encoding="utf-8").write(new_ftr)

    # Embed Simulink screenshot into word/media/ and document.xml.rels
    assert os.path.isfile(SIMULINK_PNG), f"Missing {SIMULINK_PNG}"
    shutil.copyfile(SIMULINK_PNG, os.path.join(WORK_DIR, "word", "media", "simulink_stepper.png"))
    rels_path = os.path.join(WORK_DIR, "word", "_rels", "document.xml.rels")
    rels_xml = open(rels_path, "r", encoding="utf-8").read()
    rel_entry = (
        '<Relationship Id="rId15" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
        'Target="media/simulink_stepper.png"/>'
    )
    rels_xml = rels_xml.replace("</Relationships>", rel_entry + "</Relationships>")
    ET.fromstring(rels_xml.encode("utf-8"))
    open(rels_path, "w", encoding="utf-8").write(rels_xml)

    # Repack .docx
    with zipfile.ZipFile(OUT_DOCX, "w", zipfile.ZIP_DEFLATED) as zout:
        for root, _, files in os.walk(WORK_DIR):
            for fn in sorted(files):
                fp = os.path.join(root, fn)
                arc = os.path.relpath(fp, WORK_DIR)
                zout.write(fp, arc)

    print("WROTE:", OUT_DOCX, "bytes:", os.path.getsize(OUT_DOCX))


if __name__ == "__main__":
    main()
