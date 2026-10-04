"""
Render the policy markdown files in docs/policies/ into PDFs for
AI_PARSE_DOCUMENT -> Cortex Search (Layer 3).

Supports the small markdown subset used in those files: '#', '##' headings
and plain paragraphs. Each page has a footer with the document id and page
number so parsed chunks can be cited as "doc / section / page".

Usage:
    pip install reportlab
    python data_gen/build_policy_pdfs.py
"""

from pathlib import Path

from reportlab.lib.enums import TA_JUSTIFY
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "policies"
OUT = SRC / "pdf"

styles = getSampleStyleSheet()
H1 = ParagraphStyle("H1", parent=styles["Title"], fontSize=16, leading=20, spaceAfter=6)
H2 = ParagraphStyle("H2", parent=styles["Heading2"], fontSize=12.5, spaceBefore=10, spaceAfter=4)
BODY = ParagraphStyle("Body", parent=styles["BodyText"], fontSize=10, leading=13.5,
                      alignment=TA_JUSTIFY, spaceAfter=5)
META = ParagraphStyle("Meta", parent=BODY, fontSize=8.5, textColor="#555555", alignment=0)


def esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build(md_path: Path) -> Path:
    doc_id = md_path.stem.split("_")[0]
    lines = md_path.read_text(encoding="utf-8").splitlines()
    story, first_para = [], True
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith("# "):
            story.append(Paragraph(esc(line[2:]), H1))
        elif line.startswith("## "):
            story.append(Paragraph(esc(line[3:]), H2))
        else:
            story.append(Paragraph(esc(line), META if first_para or line.startswith("Classification") else BODY))
            first_para = False
    story.append(Spacer(1, 8 * mm))
    story.append(Paragraph(f"-- End of {doc_id} --", META))

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColorRGB(0.4, 0.4, 0.4)
        canvas.drawString(18 * mm, 10 * mm, f"TraceLedger Bank | {doc_id} | Synthetic - for demo use only")
        canvas.drawRightString(A4[0] - 18 * mm, 10 * mm, f"Page {doc.page}")
        canvas.restoreState()

    OUT.mkdir(parents=True, exist_ok=True)
    pdf_path = OUT / f"{md_path.stem}.pdf"
    SimpleDocTemplate(str(pdf_path), pagesize=A4, leftMargin=18 * mm, rightMargin=18 * mm,
                      topMargin=16 * mm, bottomMargin=18 * mm, title=md_path.stem,
                      author="TraceLedger Compliance").build(story, onFirstPage=footer, onLaterPages=footer)
    return pdf_path


if __name__ == "__main__":
    for md in sorted(SRC.glob("*.md")):
        print(f"  {build(md).relative_to(ROOT)}")
