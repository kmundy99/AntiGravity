import requests
from bs4 import BeautifulSoup
import re

url = "https://northshore.tenniscores.com/?mod=nndz-TjJiOWtORzkwTlJFb0NVU1NzOD0%3D&team=nndz-WkNPL3dMci8%3D"
resp = requests.get(url)
soup = BeautifulSoup(resp.text, 'lxml')

match_url = None
for a in soup.find_all("a", href=True):
    href = a["href"]
    if "print_match.php" in href:
        if href.startswith("http"):
            match_url = href
        else:
            match_url = f"https://northshore.tenniscores.com/{href.lstrip('/')}"
        break

print("Found match URL:", match_url)
if match_url:
    match_resp = requests.get(match_url)
    match_soup = BeautifulSoup(match_resp.text, 'html.parser')
    for tr in match_soup.find_all("tr"):
        print(tr.get_text(separator=' | ').strip())
