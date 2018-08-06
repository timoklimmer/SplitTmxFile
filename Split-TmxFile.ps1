<#
.SYNOPSIS
Splits a large TMX file into multiple smaller files.

.DESCRIPTION
Reads the specified TMX file and creates new TMX files on-the-fly whenever a specified threshold of written bytes has been reached.

.PARAMETER $InputFile
The file to split.

.PARAMETER $SplitThreshold
The number of bytes after which the script should initiate a split. May also be specified in MB or GB notation, eg. 100MB or 1GB. Minimum is 64KB.

.PARAMETER $OutputDir
The output directory.

.EXAMPLE
.\Split-TmxFile.ps1 -InputFile SomeRandomTmxFile.tmx -SplitThreshold 2MB
Splits the SomeRandomTmxFile.tmx whenever 2MB have been written.

.EXAMPLE
.\Split-TmxFile.ps1 -InputFile SomeRandomTmxFile.tmx -SplitThreshold 2MB -OutputDir "C:\SomeOutputDir"
Splits the SomeRandomTmxFile.tmx whenever 2MB have been written and stores the output files in C:\SomeOutputDir.

.NOTES
- The script does not load the entire file into memory, so it should be able to split files of any size.
- The script does not guarantee a maximum file size. It rather initiates the split after SplitThreshold bytes. Hence, the resulting output files can be larger than the size specified by SplitThreshold but should have roughly the size of SplitThreshold.
- Written and tested in PowerShell 5.1 and PowerShell Core 6.0.3 but may run in other versions as well. Ensure proper testing if you are using other versions of PowerShell.
- The script assumes that the TMX's XML is formatted. It will not work if all XML is in a single line.
- This script is provided "as is". Feel free to use and modify if needed.
#>

# Parameters
param (
	[Parameter(Mandatory = $True, Position=0, HelpMessage="The file to split.")]
	[ValidateNotNullOrEmpty()]
	[string] $InputFile,

	[Parameter(Mandatory = $False, HelpMessage="The output directory.")]
	[string] $OutputDir = ".",

	[Parameter(Mandatory = $False, HelpMessage="Maximum file size for each created TMX file.")]
	[int64] $SplitThreshold = 100MB
)

# initialization
	# stop on error
	$ErrorActionPreference = "Stop";
	# log start time
	$startTime = Get-Date;
	# resolve input file
	$InputFile = Resolve-Path $InputFile
	# resolve output directory
	$OutputDir = Resolve-Path $OutputDir

# helper functions
# Format-FileSize
function Format-FileSize() {
    Param ([int64]$size)
    if     ($size -gt 1TB) { "$($size / 1TB -f '0.##') TB" }
    elseif ($size -gt 1GB) { "$($size / 1GB -f '0.##') GB" }
    elseif ($size -gt 1MB) { "$($size / 1MB -f '0.##') MB" }
    elseif ($size -gt 1KB) { "$($size / 1KB -f '0.##') KB" }
    elseif ($size -gt 0)   { "$($size -f '0.##') B" }
    else                   {""}
}
# Get-Encoding()
# Note: StreamReader.CurrentEncoding does not seem to work here, hence we use our own function
function Get-Encoding([string] $filePath) {

    # use the default encoding if the file has no 4 bytes
    if ((Get-Item $filePath -Force).length -lt 4) {
        return [System.Text.Encoding]::Default;
    }

    # else read the first 4 bytes and compute the result based on these
    # note: PowerShell Core does not support Encoding Byte, hence we have to use -AsByteStream
    #       which is not supported in PowerShell Desktop ;-)
    $byte = if ($PSVersioNTable.PSEdition -eq "Core") {
        Get-Content -AsByteStream -ReadCount 4 -TotalCount 4 -Path $filePath;
    } else {
        Get-Content -Encoding Byte -ReadCount 4 -TotalCount 4 -Path $filePath;
    }

    if ($byte[0] -eq 0xef -and $byte[1] -eq 0xbb -and $byte[2] -eq 0xbf ) {
        # UTF-8
        return [System.Text.Encoding]::UTF8;
    }  
    elseif ($byte[0] -eq 0xfe -and $byte[1] -eq 0xff) {
        # BigEndianCode
        return [System.Text.Encoding]::BigEndianUnicode;
    }
    elseif ($byte[0] -eq 0xff -and $byte[1] -eq 0xfe) {
        # Unicode
        return [System.Text.Encoding]::Unicode;
    }
    elseif ($byte[0] -eq 0 -and $byte[1] -eq 0 -and $byte[2] -eq 0xfe -and $byte[3] -eq 0xff) {
        # UTF-32
        return [System.Text.Encoding]::UTF32;
    }
    elseif ($byte[0] -eq 0x2b -and $byte[1] -eq 0x2f -and $byte[2] -eq 0x76) {
        # UTF7
        return [System.Text.Encoding]::UTF7;
    }
    else {
        return [System.Text.Encoding]::Default;
    }
}

# print welcome and parameter values
Write-Host "Splitting TMX file..."
Write-Host "---------------------"
Write-Host "Input File              : $([System.IO.Path]::GetFileName($InputFile))"
Write-Host "in directory              $([System.IO.Path]::GetDirectoryName($InputFile))"
Write-Host "Output Directory        : $OutputDir"
Write-Host "Split threshold         : $(Format-FileSize $SplitThreshold) ($SplitThreshold bytes)"
Write-Host ""
Write-Host "Start time: $startTime"
Write-Host ""

# ensure that we have a minimum SplitThreshold value to avoid trouble with corrupted headers
if ($SplitThreshold -lt 64KB) {
    throw [System.ArgumentException] "Minimum split threshold is 64KB. Specify a larger parameter value."
}

# determine common head and tail
# note: we read the beginning and end of the input file here and apply some regex to determine the head and tail we
#       have to write in each individual output file. there may be better options when we are guaranteed that we
#       work with smaller files. however, this cannot be guaranteed here, hence we fall back to a regex approach.
Write-Host "Determining head and tail for the individual output files..."
$head = ([regex] "(?sn)^.+?\<body\>\s*").Matches((Get-Content $InputFile -TotalCount 10000 | Out-String))[0].Value
$tail = ([regex] "(?sn)(?<=\r?\n)\s*\<\/body\>.+$").Matches((Get-Content $InputFile -Tail 10000 | Out-String))[0].Value

# compute and write output files
Write-Host "Computing and writing output files..."
$inputFileReader = $NULL
$currentOutputFileWriter = $NULL
$currentOutputFileNumber = 0
$outputFilePattern = "$([System.IO.Path]::GetFileName($InputFile)).split.{number}.tmx"
try {
    # open input file reader
    $inputFileEncoding = (Get-Encoding $InputFile)
    $inputFileReader = [System.IO.StreamReader]::new($InputFile, $inputFileEncoding)
    
    # determine first output file and path
    $currentOutputFileName = $outputFilePattern -replace '{number}', $currentOutputFileNumber
    $currentOutputFilePath = [System.IO.Path]::Combine($OutputDir, $currentOutputFileName)
    
    # print current file name
    Write-Host "$currentOutputFileName..."
    # open output file writer
    $currentOutputFileWriter = [System.IO.StreamWriter]::new($currentOutputFilePath, $False, $inputFileEncoding)
    
    # walk through the input file and write output files
    while ($inputFileReader.Peek() -ge 0) {
        # read next line and write it to output file
        $currentLine = $inputFileReader.ReadLine()
        $currentOutputFileWriter.WriteLine($currentLine)
        
        # check if we have reached the threshold for the split
        if ($currentOutputFileWriter.BaseStream.Position -ge $SplitThreshold) {
            # yes, we have reached the threshold
            
            # finish the current file
            # read/write until we pass a </tu>
            while ($inputFileReader.Peek() -ge 0) {
                $currentLine = $inputFileReader.ReadLine()
                $currentOutputFileWriter.WriteLine($currentLine)
                if ($currentLine.Contains("</tu>")) {
                    break
                }
            }
            # write the tail and close the writer
            $currentOutputFileWriter.Write($tail)
            $currentOutputFileWriter.Close()

            # continue with a new file
            $currentOutputFileNumber += 1
            $currentOutputFileName = $outputFilePattern -replace '{number}', $currentOutputFileNumber
            $currentOutputFilePath = [System.IO.Path]::Combine($OutputDir, $currentOutputFileName)
            Write-Host "$currentOutputFileName..."
            $currentOutputFileWriter = [System.IO.StreamWriter]::new($currentOutputFilePath, $False, $inputFileEncoding)
            $currentOutputFileWriter.Write($head)
        }
    }
}
finally {
    # ensure that the current output writer is closed
    if ($currentOutputFileWriter -ne $NULL) {
        $currentOutputFileWriter.Close()
    }
    # ensure that the input file reader is closed
    if ($inputFileReader -ne $NULL) {
        $inputFileReader.Close()
    }
}

# write done message
Write-Host "`nDone. Command took '$($(Get-Date) - $startTime)'."
