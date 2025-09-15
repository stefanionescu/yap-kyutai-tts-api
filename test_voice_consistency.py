#!/usr/bin/env python3
"""
Test script to verify the voice consistency fixes.

This script:
1. Runs the TTS client multiple times with the same text
2. Saves each output with a unique filename
3. Reports whether the voice consistency issues have been resolved

Run after starting the TTS server with the updated configuration.
"""

import asyncio
import subprocess
import time
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
AUDIO_DIR = ROOT_DIR / "audio"
TEST_TEXT = "Hey dude! It's an honor to meet you!"

def run_single_test(run_number: int) -> Path:
    """Run a single TTS test and return the output file path."""
    timestamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    output_file = AUDIO_DIR / f"consistency_test_run_{run_number:02d}_{timestamp}.wav"
    
    cmd = [
        "python", 
        str(ROOT_DIR / "test" / "client.py"),
        "--text", TEST_TEXT,
        "--outfile", str(output_file)
    ]
    
    print(f"Running test {run_number}/5...")
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT_DIR)
    
    if result.returncode != 0:
        print(f"Error in test {run_number}: {result.stderr}")
        return None
    
    return output_file

def main():
    print("=== Voice Consistency Test ===")
    print(f"Text: '{TEST_TEXT}'")
    print("Running 5 identical requests to test for voice consistency...")
    print()
    
    output_files = []
    
    for i in range(1, 6):
        output_file = run_single_test(i)
        if output_file and output_file.exists():
            output_files.append(output_file)
            file_size = output_file.stat().st_size
            print(f"✓ Test {i} completed: {output_file.name} ({file_size} bytes)")
        else:
            print(f"✗ Test {i} failed")
        
        # Small delay between tests
        if i < 5:
            time.sleep(1)
    
    print()
    print("=== Results ===")
    print(f"Generated {len(output_files)} audio files:")
    for file_path in output_files:
        print(f"  - {file_path}")
    
    print()
    print("=== Manual Verification Steps ===")
    print("1. Listen to all generated files - they should have:")
    print("   ✓ No unwanted sounds before 'Hey' (prefix trimming working)")
    print("   ✓ Consistent voice/timbre across all runs (deterministic sampling working)")
    print("   ✓ Only slight prosodic variation is acceptable")
    print()
    print("2. If voice still varies between runs:")
    print("   - Check server logs for voice loading messages")
    print("   - Verify server config has temp=0, cfg_coef=1.2, seed=42")
    print("   - Ensure server is using the exact same .safetensors file")
    print()
    print("3. If prefix artifact persists:")
    print("   - Check that first audio frames are being trimmed")
    print("   - Verify no leading space on first text chunk")

if __name__ == "__main__":
    main()
