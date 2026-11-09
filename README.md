# Zapret-general-lists-merge-script
Script for combining domains from list-general

merge-list-general.ps1 - **script**

merge-list-general.bat - **the file that executes the script**

merge-list-general-no-backup.bat - **the file that executes the script with no backup**

# You must specify your Zapret folder
It is necessary to open the .ps1 file and measure C:\Zapret to the folder where Zapret is located.

The script looks through all the list-general. Collects all the domains from them, and adds all the missing domains to all the list-general. Due to this, it is not necessary to manually register list-general in each new version of Zapret. It is enough to run the script.

```C:\Zapret\merge-list-general.bat -Root "E:\zapret" -DryRun``` - Just to see the change plan

```C:\Zapret\merge-list-general.bat -NoBackup``` - Executes the script without backups. There is a second .bat file for this

```C:\Zapret\merge-list-general.bat -DryRun -Verbose``` - Show which records are being added
