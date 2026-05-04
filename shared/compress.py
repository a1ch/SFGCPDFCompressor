# compress.py - PDF compression using PyMuPDF + img2pdf
import os
import tempfile
import fitz
import img2pdf
from PIL import Image


def compress_pdf(input_path, output_path, target_width=900, mode="bw"):
    """
    Compress a scanned PDF by rendering each page to a target width,
    converting to 1-bit B&W PNG, then repacking with img2pdf.
    Achieves ~80% reduction on large scanned documents.
    """
    print(f"  Compressing: {input_path} -> {output_path} (target width: {target_width}px, mode: {mode})")

    doc = fitz.open(input_path)
    print(f"  Opened: {len(doc)} pages, {doc[0].rect.width:.0f}x{doc[0].rect.height:.0f} pts")

    with tempfile.TemporaryDirectory() as tmpdir:
        png_files = []
        page_sizes = []

        for i, page in enumerate(doc):
            page_w = page.rect.width
            page_h = page.rect.height
            scale = target_width / page_w

            pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), colorspace=fitz.csGRAY)
            img = Image.frombytes('L', [pix.width, pix.height], pix.samples)
            if mode == 'bw':
                img = img.convert('1')
            path = os.path.join(tmpdir, f'p{i:04d}.png')
            img.save(path, format='PNG', optimize=True)
            png_files.append(path)
            page_sizes.append((page_w, page_h))
            if (i + 1) % 50 == 0:
                print(f"  Rendered {i+1}/{len(doc)} pages")

        print(f"  Assembling {len(png_files)} pages into PDF...")

        pdf_pages = []
        for png_path, (pw, ph) in zip(sorted(png_files), page_sizes):
            page_bytes = img2pdf.convert(
                png_path,
                layout_fun=img2pdf.get_layout_fun((pw, ph))
            )
            pdf_pages.append(page_bytes)

        out_doc = fitz.open()
        for page_bytes in pdf_pages:
            tmp = fitz.open("pdf", page_bytes)
            out_doc.insert_pdf(tmp)
            tmp.close()
        out_doc.save(output_path, garbage=4, deflate=True)
        out_doc.close()

        written = os.path.getsize(output_path)
        print(f"  Done: {len(png_files)} pages, {round(written/1024/1024, 2)} MB output")

    doc.close()
