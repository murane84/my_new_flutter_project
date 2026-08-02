from fastapi import APIRouter, UploadFile, File, Depends, HTTPException, Request
from pathlib import Path
import shutil
import uuid
from models import User
from .users import get_current_user

router = APIRouter(
    prefix="/upload",
    tags=["Upload"]
)

# 📁 Base upload directory
BASE_UPLOAD_DIR = Path("media")
AUDIO_UPLOAD_DIR = BASE_UPLOAD_DIR / "audio"

AUDIO_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)


# ✅ Upload Audio File
@router.post("/audio")
async def upload_audio(
    request: Request,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user)
):
    try:
        # 🔐 Restrict file types
        allowed_extensions = ["mp3", "wav", "m4a", "aac"]
        file_extension = (file.filename or "").split(".")[-1].lower()

        if file_extension not in allowed_extensions:
            raise HTTPException(
                status_code=400,
                detail="Unsupported audio format"
            )

        # Generate unique filename
        unique_name = f"{uuid.uuid4()}.{file_extension}"
        file_path = AUDIO_UPLOAD_DIR / unique_name

        # Save file
        with file_path.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)

        # Build an absolute URL from the incoming request so it works both
        # locally and on the deployed host (no hardcoded IP/port).
        base = str(request.base_url).rstrip("/")
        return {"url": f"{base}/media/audio/{unique_name}"}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
