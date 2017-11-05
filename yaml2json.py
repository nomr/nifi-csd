import click
import yaml
import json

@click.command()
@click.argument('input', type=click.File('rb'))
@click.argument('output', type=click.File('wb'))
def main(input, output):
  y = yaml.load(input)
  json.dump(y, output, indent=2, sort_keys=True)
  
if __name__ == "__main__":
  main()
